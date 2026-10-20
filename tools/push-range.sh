#!/usr/bin/env bash
# Resolve the commit range a `git push` would publish and validate it.
#
# Why reconstruction: lefthook consumes the pre-push standard input (the
# "<local-ref> <local-sha> <remote-ref> <remote-sha>" lines) and exposes only
# the remote name and URL to commands and scripts (verified on lefthook
# 2.1.16). This helper therefore rebuilds the pushed commit set itself, in
# decreasing order of fidelity:
#
#   1. refspec mode — the `git push ...` command line found among the /proc
#      ancestors is parsed for refspecs; each refspec yields the exact range
#      (remote-tracking ref or merge-base with <remote>/main .. pushed sha).
#      Covers first pushes, cross-branch pushes, force pushes and multi-ref
#      pushes.
#   2. current-branch mode — no `git push` ancestor (manual `lefthook run
#      pre-push` runs) or a bare `git push`: validate what a push of the
#      current branch would carry, based on @{push}, the remote-tracking ref,
#      and/or the merge-base with <remote>/main, folded to the deepest common
#      ancestor (a conservative superset).
#   3. wide mode — `--all/--mirror/--tags/--follow-tags`, an unparseable push
#      command line, or push.default=matching: every local non-merge commit
#      not known to be on the remote is validated one by one.
#
# A push with no determinable baseline FAILS. An empty range is reported as
# NO_NEW_COMMITS. Nothing here writes, stages, amends or touches the network.
#
# Usage:
#   tools/push-range.sh [validate|whitespace|print] [remote] [--range B H]
#     validate    (default) run tools/check-commit.sh --range per resolved range
#     whitespace  run `git diff --check` per commit of each resolved range
#     print       print resolved ranges as "<base> <head>" lines
#   DUDUDU_PUSH_REMOTE overrides the remote (default: argument, else origin)

set -u -o pipefail
export LC_ALL=C.UTF-8

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'push-range: ERROR: not inside a git repository\n' >&2
  exit 1
}
CHECKER="$REPO_ROOT/tools/check-commit.sh"
MODE="validate"
REMOTE="${DUDUDU_PUSH_REMOTE:-}"
RANGE_OVERRIDE_BASE=""
RANGE_OVERRIDE_HEAD=""

usage() {
  cat >&2 <<EOF
usage: tools/push-range.sh [validate|whitespace|print] [remote] [--range BASE HEAD]
  validate    run the commit checker on every resolved push range (default)
  whitespace  git diff --check every commit of the resolved ranges
  print       print resolved ranges as "<base> <head>" lines
  remote      remote name (lefthook passes it as {1}; default: origin)
  --range B H validate the explicit range instead of resolving the push
exit codes: 0 pass, 1 policy failure or undeterminable push, 2 usage error
EOF
}

die() { printf 'push-range: ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'push-range: %s\n' "$*"; }

# --- argument parsing --------------------------------------------------------
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    validate|whitespace|print) MODE="$1"; shift ;;
    --range) [ $# -ge 3 ] || { usage; exit 2; }
             RANGE_OVERRIDE_BASE="$2"; RANGE_OVERRIDE_HEAD="$3"; shift 3 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'push-range: ERROR: unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
if [ -z "$REMOTE" ]; then
  REMOTE="${ARGS[0]:-origin}"
fi

verify_commit() { git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

# empty-tree object hash, used to diff-check root commits
EMPTY_TREE="$(git hash-object -t tree /dev/null)"

# --- push command-line recovery ----------------------------------------------
# Walk the /proc ancestor chain looking for the `git push ...` invocation this
# hook (however deeply lefthook nests it) belongs to. Returns 0 and sets
# PUSH_ARGS (array of args after "push") when found.
find_push_args() {
  PUSH_ARGS=()
  local pid self="$BASHPID" argv0 i depth=0
  pid="$self"
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$depth" -lt 10 ]; do
    local -a argv=()
    mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || { argv=(); }
    if [ "${#argv[@]}" -ge 2 ]; then
      argv0="${argv[0]##*/}"
      if [ "$argv0" = "git" ] && [ "${argv[1]}" = "push" ]; then
        for ((i = 2; i < ${#argv[@]}; i++)); do
          PUSH_ARGS+=("${argv[$i]}")
        done
        return 0
      fi
    fi
    pid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    depth=$((depth + 1))
  done
  return 1
}

# Parse the recovered git push argument vector. Sets:
#   SPECS[]          refspecs (positional args minus the remote)
#   WIDE=1           --all/--mirror/--tags/--follow-tags present
#   SPECS_RELIABLE=1 args were fully understood
parse_push_args() {
  SPECS=()
  WIDE=0
  SPECS_RELIABLE=1
  local -a novalue=(
    -q --quiet -v --verbose -f --force -n --dry-run --all --branches --mirror
    --tags --follow-tags --atomic --porcelain -u --set-upstream -t --thin
    --no-verify --verify --force-with-lease --force-if-includes
    --no-force-if-includes --no-signed --signed --prune --no-prune
    --no-thin --progress --no-progress --no-recurse-submodules -4 --ipv4
    -6 --ipv6
  )
  local -a withvalue=( -o --push-option --receive-pack --exec --repo --recurse-submodules --server-option )
  local arg seen_remote=0 i j known
  for ((i = 0; i < ${#PUSH_ARGS[@]}; i++)); do
    arg="${PUSH_ARGS[$i]}"
    if [[ $arg == -* ]]; then
      known=0
      for j in "${novalue[@]}"; do [ "$arg" = "$j" ] && { known=1; break; }; done
      if [ "$known" -eq 0 ]; then
        for j in "${withvalue[@]}"; do [ "$arg" = "$j" ] && { known=2; break; }; done
      fi
      # combined short flags (e.g. -qu, -fu): fine when every letter is a
      # known value-less option
      if [ "$known" -eq 0 ] && [[ $arg =~ ^-[qvfntu]+$ ]]; then
        known=1
      fi
      case "$arg" in
        --all|--branches|--mirror|--tags|--follow-tags) WIDE=1 ;;
      esac
      if [ "$known" -eq 1 ]; then
        :
      elif [ "$known" -eq 2 ]; then
        i=$((i + 1))                  # consume the flag's value
      elif [[ $arg == *=* ]]; then
        :                             # unknown flag with embedded value: keep going
      else
        SPECS_RELIABLE=0              # unknown bare flag: do not trust the rest
        WIDE=1
      fi
    elif [ "$seen_remote" -eq 0 ]; then
      REMOTE="$arg"                   # first positional is the remote
      seen_remote=1
    else
      SPECS+=("$arg")
    fi
  done
}

# --- range construction ------------------------------------------------------
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

# refspec_range <refspec>: prints "<base> <head>" for one refspec, or returns
# 2 for a deletion (nothing to validate). Fails hard when no baseline exists.
refspec_range() {
  local rs="$1" src dst sha tracking base
  rs="${rs#+}"
  if [[ $rs == *:* ]]; then
    src="${rs%%:*}"
    dst="${rs##*:}"
  else
    src="$rs"
    dst="$rs"
  fi
  if [ -z "$src" ]; then
    note "refspec '$rs' deletes '$dst': no commits to validate"
    return 2
  fi
  sha="$(git rev-parse --verify --quiet "${src}^{commit}")" ||
    die "cannot resolve pushed source '$src' as a commit"
  dst="${dst#refs/heads/}"
  tracking="refs/remotes/$REMOTE/$dst"
  if verify_commit "$tracking"; then
    printf '%s %s' "$tracking" "$sha"
    return 0
  fi
  base="$(baseline_base "$sha")" ||
    die "cannot determine the push base for '$rs': no remote-tracking ref '$tracking' and no $REMOTE/main (or $REMOTE/master) baseline. Fetch the remote (git fetch $REMOTE) or push once with an explicit range check."
  printf '%s %s' "$base" "$sha"
}

# current_branch_range: prints "<base> <head>" for the current branch, using
# every baseline git knows about, folded to the deepest common ancestor.
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

# wide_ranges: prints one "<base> <sha>" pair per local non-merge commit not
# known to be on the remote (per-commit, because such a set has no single
# base that is an ancestor of HEAD).
wide_ranges() {
  local sha parent
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    if parent="$(git rev-parse --verify --quiet "${sha}^" 2>/dev/null)"; then
      printf '%s %s\n' "$parent" "$sha"
    else
      die "wide push contains a root commit ($sha) that cannot be range-checked; run an explicit check instead: bash tools/check-commit.sh --range <base> <head>"
    fi
  done < <(git rev-list --reverse --no-merges --branches --tags --not "refs/remotes/$REMOTE/*" 2>/dev/null)
}

# --- resolution ---------------------------------------------------------------
resolve_ranges() {
  RANGES=()
  if [ -n "$RANGE_OVERRIDE_BASE" ]; then
    verify_commit "$RANGE_OVERRIDE_BASE" || die "cannot resolve override base '$RANGE_OVERRIDE_BASE'"
    verify_commit "$RANGE_OVERRIDE_HEAD" || die "cannot resolve override head '$RANGE_OVERRIDE_HEAD'"
    RANGES+=("$RANGE_OVERRIDE_BASE $RANGE_OVERRIDE_HEAD")
    note "mode=override remote=$REMOTE range=$RANGE_OVERRIDE_BASE..$RANGE_OVERRIDE_HEAD"
    return 0
  fi

  if find_push_args; then
    parse_push_args
    if [ "${#SPECS[@]}" -gt 0 ] && [ "$SPECS_RELIABLE" -eq 1 ] && [ "$WIDE" -eq 0 ]; then
      local rs r out rc
      note "mode=refspec remote=$REMOTE specs=${SPECS[*]}"
      for rs in "${SPECS[@]}"; do
        out=""
        rc=0
        out="$(refspec_range "$rs")" || rc=$?
        [ "$rc" -eq 2 ] && continue          # deletion: nothing to validate
        RANGES+=("$out")
      done
      return 0
    fi
    if [ "$WIDE" -eq 1 ]; then
      note "mode=wide remote=$REMOTE (unrecognized or multi-ref push: every local commit not on $REMOTE is validated)"
      wide_ranges_validated=1
      local line
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        RANGES+=("$line")
      done < <(wide_ranges)
      if [ "${#RANGES[@]}" -eq 0 ]; then
        note "NO_NEW_COMMITS: nothing local is missing from $REMOTE"
      fi
      return 0
    fi
    # reliable-looking bare `git push` (no refspecs): push.default decides
    if [ "$(git config push.default 2>/dev/null || printf simple)" = "matching" ]; then
      WIDE=1
      note "mode=wide remote=$REMOTE (push.default=matching)"
      local line
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        RANGES+=("$line")
      done < <(wide_ranges)
      if [ "${#RANGES[@]}" -eq 0 ]; then
        note "NO_NEW_COMMITS: nothing local is missing from $REMOTE"
      fi
      return 0
    fi
  fi

  local out
  out="$(current_branch_range)"
  RANGES+=("$out")
  note "mode=current-branch remote=$REMOTE range=${out% *}"
  return 0
}

# --- checks -------------------------------------------------------------------
do_validate() {
  local r base head rc total=0
  if [ "${#RANGES[@]}" -eq 0 ]; then
    note "nothing to validate (deletion-only or no-op push)"
    return 0
  fi
  for r in "${RANGES[@]}"; do
    base="${r% *}"
    head="${r##* }"
    bash "$CHECKER" --range "$base" "$head" --label "pushed commit" || return 1
    total=$((total + 1))
  done
  return 0
}

do_whitespace() {
  local r base head sha parent bad=0 n=0
  for r in "${RANGES[@]}"; do
    base="${r% *}"
    head="${r##* }"
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      n=$((n + 1))
      local err
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
  if [ "$bad" -ne 0 ]; then
    printf 'push-range: ERROR: whitespace violations in the pushed commits\n' >&2
    return 1
  fi
  note "whitespace: $n commit(s) checked, clean"
  return 0
}

do_print() {
  local r
  for r in "${RANGES[@]}"; do
    printf '%s\n' "$r"
  done
  [ "${#RANGES[@]}" -gt 0 ] || note "no ranges (deletion-only or no-op push)"
}

resolve_ranges
case "$MODE" in
  validate)   do_validate ;;
  whitespace) do_whitespace ;;
  print)      do_print ;;
esac
