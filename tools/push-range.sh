#!/usr/bin/env bash
# Validate the commits a push publishes, from Git's own pre-push data.
#
# Git writes one line per ref it will update to the pre-push hook's stdin:
#
#   <local ref> <local sha> <remote ref> <remote sha>
#
# That stream already reflects Git's option parsing, remote.<name>.push
# recipes, explicit/wildcard/negative refspecs, matching refspecs (`:` and
# `+:`), --all/--branches/--tags/--follow-tags and --mirror. lefthook 2.1.16
# replays the stream to every command that sets `use_stdin: true` and expands
# `{1}` to the remote argument Git passed to the hook. This script validates
# exactly the SHAs Git reports. It no longer reconstructs the push set from
# the command line: that emulation had to reimplement Git's refspec, config
# and mirror semantics and repeatedly went green on a ref it had misparsed.
#
# Resolution rules:
#   * local sha is the zero id — deletion, no commits to validate;
#   * remote sha is non-zero and present locally — validate remote..local,
#     the exact commit set this ref publishes;
#   * remote sha is zero (new remote ref) or absent locally — validate every
#     commit NOT reachable from the immutable pre-policy boundary, because
#     Git's line alone cannot establish a narrower, still-safe base. History
#     reachable from that boundary is grandfathered R0 history and is never
#     re-judged; a new commit, a new side branch or an unrelated root is
#     still checked;
#   * malformed line, missing local object, or a manual run with no baseline —
#     hard failure. Never guess a narrower set, never report NO_NEW_COMMITS
#     for something that was not checked.
#
# A real push always supplies the stream; an empty stream means Git has no ref
# to publish and is reported as NO_NEW_COMMITS. A manual `lefthook run
# pre-push` has no push data (lefthook leaves `{1}` literal), so the script
# validates the current branch against its tracking/baseline ref, or an
# explicit --range. It never writes, stages, amends or touches the network.
#
# Usage:
#   tools/push-range.sh [validate|whitespace|relevant|files|print] [remote] [--range B H]
#     validate    (default) run tools/check-commit.sh over the pushed commits
#     whitespace  run `git diff --check` per commit of each resolved range
#     relevant    exit 0 when the pushed set touches build-relevant paths,
#                 1 when it is docs/metadata only, 2 when undeterminable
#     files       print the changed files of the resolved ranges
#     print       print resolved ranges as "<base> <head>" lines
#   remote      manual-mode default (origin when omitted; on a real push the
#               remote from the hook's `{1}` wins)
#   DUDUDU_PUSH_REMOTE supplies a manual-mode default remote.
#   DUDUDU_PRE_PUSH_REMOTE is set by the hook wrapper; the literal `{1}` that
#   lefthook leaves in manual runs selects manual mode.
#   DUDUDU_FORCE_BUILD_GATE=1 makes `relevant` report 0 unconditionally, so
#   the manual full gate can force build+CTest on a docs-only range.
#   DUDUDU_GRANDFATHER_BOUNDARY overrides the fixed pre-policy boundary. It is
#   a test seam only; production runs use the immutable R0 main SHA below.

set -u -o pipefail
export LC_ALL=C.UTF-8

# The pre-R0.1 main tip (merge of the R0 foundation). Every commit reachable
# from this SHA predates the required-scope policy and is never re-judged.
# Deliberately a fixed commit id, not a moving ref such as origin/main: a
# moving base would silently exempt whatever main contains at push time.
readonly GRANDFATHER_BOUNDARY_DEFAULT="6e5f5c6db08f5b6780e13d92f357c65cdc865538"
GRANDFATHER_BOUNDARY="${DUDUDU_GRANDFATHER_BOUNDARY:-$GRANDFATHER_BOUNDARY_DEFAULT}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'push-range: ERROR: not inside a git repository\n' >&2
  exit 1
}
CHECKER="$REPO_ROOT/tools/check-commit.sh"
MODE="validate"
REMOTE=""
RANGE_OVERRIDE_BASE=""
RANGE_OVERRIDE_HEAD=""
DIE_CODE=1

usage() {
  cat >&2 <<EOF
usage: tools/push-range.sh [validate|whitespace|relevant|files|print] [remote] [--range BASE HEAD]
  validate    run the commit checker on the commits the push publishes (default)
  whitespace  git diff --check every commit of the resolved ranges
  relevant    exit 0 if the pushed set touches build-relevant paths, 1 if not, 2 if undeterminable
  files       print the changed files of the resolved ranges
  print       print resolved ranges as "<base> <head>" lines
  remote      manual-mode default remote (origin when omitted; a real push uses
              the remote Git passed to the pre-push hook)
  --range B H validate the explicit range instead of resolving the push
  DUDUDU_GRANDFATHER_BOUNDARY overrides the fixed pre-policy boundary (tests)
exit codes: 0 pass, 1 policy failure or undeterminable push, 2 usage error
EOF
}

die() { printf 'push-range: ERROR: %s\n' "$*" >&2; exit "$DIE_CODE"; }
note() { printf 'push-range: %s\n' "$*"; }

# --- argument parsing --------------------------------------------------------
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    validate|whitespace|relevant|files|print) MODE="$1"; shift ;;
    --range) [ $# -ge 3 ] || { usage; exit 2; }
             RANGE_OVERRIDE_BASE="$2"; RANGE_OVERRIDE_HEAD="$3"; shift 3 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'push-range: ERROR: unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# lefthook expands {1} in a real push and leaves it literal in a manual run.
# stdin is a pipe in a real hook and may be a terminal in a manual run; never
# block reading a terminal even if the environment marker is set by hand.
HOOK_REMOTE="${DUDUDU_PRE_PUSH_REMOTE:-}"
REAL_PUSH=0
if [ -n "$HOOK_REMOTE" ] && [ "$HOOK_REMOTE" != "{1}" ] && [ ! -t 0 ]; then
  REAL_PUSH=1
  REMOTE="$HOOK_REMOTE"
else
  REMOTE="${DUDUDU_PUSH_REMOTE:-${ARGS[0]:-origin}}"
fi

verify_commit() { git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }
# resolve_commit <rev>: print the commit id, nothing on failure.
resolve_commit() { git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null; }

# empty-tree object hash, used to diff-check root commits
EMPTY_TREE="$(git hash-object -t tree /dev/null)"

# --- range construction ------------------------------------------------------
RANGES=()
ROOTS=()
declare -A RANGE_SEEN=()
declare -A ROOT_SEEN=()

clear_ranges() {
  RANGES=()
  ROOTS=()
  RANGE_SEEN=()
  ROOT_SEEN=()
}

append_range() {
  local base="$1" head="$2"
  [ "$base" = "$head" ] && return 0
  [ -n "${RANGE_SEEN[$base $head]+x}" ] && return 0
  RANGE_SEEN["$base $head"]=1
  RANGES+=("$base $head")
}

append_root() {
  local sha="$1"
  [ -n "${ROOT_SEEN[$sha]+x}" ] && return 0
  ROOT_SEEN["$sha"]=1
  ROOTS+=("$sha")
}

# append_full_history <commit> <ref>: a new remote ref (or a remote object not
# present locally) has no locally provable narrower base. Exempt exactly the
# commits already reachable from the immutable R0 boundary; validate the rest,
# including a newly introduced unrelated root. When the boundary object is not
# available locally (e.g. a shallow clone), fall back to validating the whole
# history: a false rejection is recoverable, a silent pass is not.
append_full_history() {
  local commit="$1" ref="$2" base sha
  case "$GRANDFATHER_BOUNDARY" in
    ''|*[!0-9a-f]*)
      die "grandfather boundary '$GRANDFATHER_BOUNDARY' is not a lowercase hexadecimal commit id; refusing to guess which history is exempt" ;;
  esac
  if [ "${#GRANDFATHER_BOUNDARY}" -ne 40 ] && [ "${#GRANDFATHER_BOUNDARY}" -ne 64 ]; then
    die "grandfather boundary '$GRANDFATHER_BOUNDARY' is not a full commit id; refusing to guess which history is exempt"
  fi
  if base="$(resolve_commit "$GRANDFATHER_BOUNDARY")"; then
    append_range "$base" "$commit"
    note "ref $ref: validating $base..$commit (history reachable from the R0 boundary ${base:0:12} is grandfathered)"
    return 0
  fi
  note "ref $ref: grandfather boundary ${GRANDFATHER_BOUNDARY:0:12} is absent locally; validating the full history"
  local -a roots=()
  mapfile -t roots < <(git rev-list --max-parents=0 "$commit" 2>/dev/null)
  if [ "${#roots[@]}" -eq 0 ]; then
    die "cannot find a root commit for $ref ($commit); refusing to skip validation"
  fi
  for sha in "${roots[@]}"; do
    append_root "$sha"
  done
  base="${roots[0]}"
  append_range "$base" "$commit"
  note "ref $ref: validating the full history at $commit (root ${base:0:12})"
}

# read_push_lines: consume Git's official pre-push stream. Returns with RANGES
# and ROOTS filled. Die, never fall back, on anything that cannot be trusted.
read_push_lines() {
  local local_ref local_sha remote_ref remote_sha extra
  local local_commit remote_commit n=0 updates=0
  while IFS=' ' read -r local_ref local_sha remote_ref remote_sha extra; do
    if [ -z "$local_ref$local_sha$remote_ref$remote_sha$extra" ]; then
      continue
    fi
    n=$((n + 1))
    if [ -n "$extra" ]; then
      die "malformed pre-push line (more than four fields): $local_ref $local_sha $remote_ref $remote_sha $extra"
    fi
    if ! [[ $local_sha =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
      die "malformed pre-push line (bad local sha '$local_sha'): $local_ref"
    fi
    if ! [[ $remote_sha =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
      die "malformed pre-push line (bad remote sha '$remote_sha'): $remote_ref"
    fi
    if [ -z "$local_ref" ] || [ -z "$remote_ref" ]; then
      die "malformed pre-push line (empty ref name)"
    fi
    if [[ $local_sha =~ ^0+$ ]]; then
      note "ref $remote_ref: deletion, no commits to validate"
      continue
    fi
    updates=$((updates + 1))
    local_commit="$(git rev-parse --verify --quiet "${local_sha}^{commit}")" ||
      die "pre-push line names local object $local_sha ($local_ref) that cannot be resolved to a commit"
    if [[ $remote_sha =~ ^0+$ ]]; then
      append_full_history "$local_commit" "$local_ref"
    elif remote_commit="$(git rev-parse --verify --quiet "${remote_sha}^{commit}")"; then
      append_range "$remote_commit" "$local_commit"
      note "ref $remote_ref: validating $remote_commit..$local_commit"
    else
      note "ref $remote_ref: remote object $remote_sha is absent locally"
      append_full_history "$local_commit" "$local_ref"
    fi
  done

  note "mode=pre-push remote=$REMOTE refs=$n"
  if [ "$n" -eq 0 ]; then
    note "NO_NEW_COMMITS: Git reported no refs to publish"
  elif [ "$updates" -gt 0 ] && [ "${#RANGES[@]}" -eq 0 ] && [ "${#ROOTS[@]}" -eq 0 ]; then
    note "NO_NEW_COMMITS: reported refs carry no new commits"
  fi
}

# --- manual-mode baseline ----------------------------------------------------
# baseline_base <sha>: deepest fold of <remote>/main and <remote>/master
# merge-bases with <sha>; prints the base or returns 1 when no baseline exists.
baseline_base() {
  local sha="$1" b line mb=""
  local -a cands=()
  for b in main master; do
    line="refs/remotes/$REMOTE/$b"
    if verify_commit "$line"; then
      if ! mb="$(git merge-base "$line" "$sha" 2>/dev/null)"; then
        die "no common ancestor between $line and $sha; cannot build a conservative range"
      fi
      cands+=("$mb")
    fi
  done
  [ "${#cands[@]}" -gt 0 ] || return 1
  mb="${cands[0]}"
  for b in "${cands[@]:1}"; do
    mb="$(git merge-base "$b" "$mb" 2>/dev/null)" || return 1
  done
  printf '%s' "$mb"
}

# current_branch_range: prints "<base> <head>" for the current branch, using
# every baseline git knows about, folded to the deepest common ancestor. This
# is manual mode only: a real push always supplies the authoritative refs.
current_branch_range() {
  local head_sha branch c mb base
  head_sha="$(git rev-parse --verify HEAD)" || die "detached or missing HEAD"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  local -a cands=()
  if c="$(git rev-parse --verify --quiet '@{push}' 2>/dev/null)"; then
    cands+=("$c")
  fi
  if [ "$branch" != "HEAD" ] && verify_commit "refs/remotes/$REMOTE/$branch"; then
    cands+=("refs/remotes/$REMOTE/$branch")
  fi
  if c="$(baseline_base "$head_sha")"; then
    cands+=("$c")
  fi
  if [ "${#cands[@]}" -eq 0 ]; then
    die "cannot determine the push base: no '@{push}', no remote-tracking ref for '$branch', and no $REMOTE/main (or $REMOTE/master) baseline. Fetch the remote or run: bash tools/push-range.sh --range <base> HEAD"
  fi
  base="${cands[0]}"
  for c in "${cands[@]:1}"; do
    mb="$(git merge-base "$c" "$base" 2>/dev/null)" ||
      die "baselines have no common ancestor; cannot build a conservative range"
    base="$mb"
  done
  printf '%s %s' "$base" "$head_sha"
}

# --- resolution ---------------------------------------------------------------
resolve_ranges() {
  clear_ranges
  if [ -n "$RANGE_OVERRIDE_BASE" ]; then
    verify_commit "$RANGE_OVERRIDE_BASE" || die "cannot resolve override base '$RANGE_OVERRIDE_BASE'"
    verify_commit "$RANGE_OVERRIDE_HEAD" || die "cannot resolve override head '$RANGE_OVERRIDE_HEAD'"
    append_range "$RANGE_OVERRIDE_BASE" "$RANGE_OVERRIDE_HEAD"
    note "mode=override remote=$REMOTE range=$RANGE_OVERRIDE_BASE..$RANGE_OVERRIDE_HEAD"
    return 0
  fi
  if [ "$REAL_PUSH" -eq 1 ]; then
    read_push_lines
    return 0
  fi
  local out
  out="$(current_branch_range)"
  RANGES+=("$out")
  note "mode=manual remote=$REMOTE range=${out% *}..${out##* }"
  return 0
}

# --- checks -------------------------------------------------------------------
do_validate() {
  local r base head sha body
  if [ "${#RANGES[@]}" -eq 0 ] && [ "${#ROOTS[@]}" -eq 0 ]; then
    note "nothing to validate (deletion-only or no-op push)"
    return 0
  fi
  for r in "${RANGES[@]}"; do
    base="${r% *}"
    head="${r##* }"
    bash "$CHECKER" --range "$base" "$head" --label "pushed commit" || return 1
  done
  for sha in "${ROOTS[@]}"; do
    body="$(git show -s --format=%B "$sha")" || die "cannot read commit $sha"
    bash "$CHECKER" --message "$body" --label "commit ${sha:0:12}" || return 1
  done
  return 0
}

do_whitespace() {
  local r base head sha parent bad=0 n=0 err
  for r in "${RANGES[@]}"; do
    base="${r% *}"
    head="${r##* }"
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      n=$((n + 1))
      if parent="$(git rev-parse --verify --quiet "${sha}^" 2>/dev/null)"; then
        err="$(git diff --check "$parent" "$sha")"
      else
        err="$(git diff --check "$EMPTY_TREE" "$sha")"
      fi
      if [ -n "$err" ]; then
        printf 'push-range: whitespace error in %s:\n%s\n' "${sha:0:12}" "$err" >&2
        bad=1
      fi
    done < <(git rev-list --no-merges --reverse "$base..$head")
  done
  for sha in "${ROOTS[@]}"; do
    n=$((n + 1))
    err="$(git diff --check "$EMPTY_TREE" "$sha")"
    if [ -n "$err" ]; then
      printf 'push-range: whitespace error in %s:\n%s\n' "${sha:0:12}" "$err" >&2
      bad=1
    fi
  done
  if [ "$bad" -ne 0 ]; then
    printf 'push-range: ERROR: whitespace violations in the pushed commits\n' >&2
    return 1
  fi
  note "whitespace: $n commit(s) checked, clean"
  return 0
}

do_print() {
  local r sha
  for r in "${RANGES[@]}"; do
    printf '%s\n' "$r"
  done
  for sha in "${ROOTS[@]}"; do
    printf '%s %s\n' "$EMPTY_TREE" "$sha"
  done
  if [ "${#RANGES[@]}" -eq 0 ] && [ "${#ROOTS[@]}" -eq 0 ]; then
    note "no ranges (deletion-only or no-op push)"
  fi
}

# Paths whose change invalidates the compiled gate. Kept in sync with the
# build inputs listed in AGENTS.md; docs-only pushes intentionally fall
# outside it.
RELEVANT_RE='^(CMakeLists\.txt|CMakePresets\.json|cmake/|src/|include/|experiments/|tests/|benchmarks/|tools/|lefthook\.yml$|\.github/workflows/|third_party/(sluice|duckdb)$)'

do_files() {
  local r base head sha out=""
  for r in "${RANGES[@]}"; do
    base="${r% *}"
    head="${r##* }"
    out+="$(git diff --name-only "$base" "$head")"$'\n' || return 1
  done
  for sha in "${ROOTS[@]}"; do
    out+="$(git diff --name-only "$EMPTY_TREE" "$sha")"$'\n' || return 1
  done
  printf '%s' "$out" | sed '/^$/d' | sort -u
}

# Exit semantics are tri-state on purpose: 0 = build needed, 1 = docs-only,
# 2 = undeterminable (must fail the gate, never skip it).
do_relevant() {
  local files
  case "${DUDUDU_FORCE_BUILD_GATE:-0}" in
    1|true|yes)
      note "relevant: DUDUDU_FORCE_BUILD_GATE is set; forcing the build gate"
      return 0 ;;
  esac
  if [ "${#RANGES[@]}" -eq 0 ] && [ "${#ROOTS[@]}" -eq 0 ]; then
    note "relevant: deletion-only or no-op push; build gate not needed"
    return 1
  fi
  files="$(do_files)" || die "cannot diff the resolved ranges"
  if [ -z "$files" ]; then
    note "relevant: no file changes in the resolved ranges; build gate not needed"
    return 1
  fi
  if printf '%s\n' "$files" | grep -Eq "$RELEVANT_RE"; then
    note "relevant: build-relevant paths changed:"
    printf '%s\n' "$files" | grep -E "$RELEVANT_RE" | sed 's/^/  /'
    return 0
  fi
  note "relevant: only non-build paths changed; build gate not needed"
  return 1
}

if [ "$MODE" = "relevant" ]; then
  DIE_CODE=2   # an undeterminable push must fail, not read as "not relevant"
fi
resolve_ranges
case "$MODE" in
  validate)   do_validate ;;
  whitespace) do_whitespace ;;
  relevant)   do_relevant ;;
  files)      do_files ;;
  print)      do_print ;;
esac
