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
#      ancestors (including `git -c ... push`, `git -C path push`, global
#      options and command-line `-c` config) is parsed for refspecs; each
#      refspec yields the exact range (remote-tracking ref or merge-base with
#      <remote>/main .. pushed sha). Covers first pushes, cross-branch pushes,
#      force pushes, multi-ref pushes and wildcards.
#   2. configured-refspec mode — a bare `git push`/`git push <remote>` with
#      remote.<name>.push configured uses exactly those refspecs, overridden
#      or extended by command-line `-c remote.<name>.push=...`.
#   3. current-branch mode — no `git push` ancestor (manual `lefthook run
#      pre-push` runs) or a bare push under push.default=simple/current/
#      upstream: validate what a push of the current branch would carry,
#      based on @{push}, the remote-tracking ref, and/or the merge-base with
#      <remote>/main, folded to the deepest common ancestor (a conservative
#      superset).
#   4. wide/mirror mode — `--all/--tags/--follow-tags`,
#      push.default=matching, `--mirror`, or remote.<name>.mirror: every
#      local non-merge commit not known to be on the remote is validated one
#      by one. Mirror enumerates every ref namespace (notes, replace, deploy,
#      remote-tracking), not just branches and tags; wildcard refspec '*' also
#      crosses '/' exactly like Git's refspec matcher.
#
# A push command line this script cannot parse is a hard failure. Falling
# back to the current branch in that situation is exactly the fail-open bug
# the parser is here to prevent (the clean current branch would go green
# while a different ref is published).
#
# A push with no determinable baseline FAILS. An empty range is reported as
# NO_NEW_COMMITS. Nothing here writes, stages, amends or touches the network.
#
# Usage:
#   tools/push-range.sh [validate|whitespace|relevant|files|print] [remote] [--range B H]
#     validate    (default) run tools/check-commit.sh --range per resolved range
#     whitespace  run `git diff --check` per commit of each resolved range
#     relevant    exit 0 when the pushed set touches build-relevant paths,
#                 1 when it is docs/metadata only, 2 when undeterminable
#     files       print the changed files of the resolved ranges
#     print       print resolved ranges as "<base> <head>" lines
#   DUDUDU_PUSH_REMOTE supplies a default remote (origin when unset); on a
#   real push the remote parsed from the `git push` command line wins.
#   DUDUDU_FORCE_BUILD_GATE=1 makes `relevant` report 0 unconditionally, so
#   the manual full gate can force build+CTest on a docs-only range.

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
DIE_CODE=1

usage() {
  cat >&2 <<EOF
usage: tools/push-range.sh [validate|whitespace|relevant|files|print] [remote] [--range BASE HEAD]
  validate    run the commit checker on every resolved push range (default)
  whitespace  git diff --check every commit of the resolved ranges
  relevant    exit 0 if the pushed set touches build-relevant paths, 1 if not, 2 if undeterminable
  files       print the changed files of the resolved ranges
  print       print resolved ranges as "<base> <head>" lines
  remote      default remote name (origin when omitted; on a real push the
              remote parsed from the git push command line wins)
  --range B H validate the explicit range instead of resolving the push
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
if [ -z "$REMOTE" ]; then
  REMOTE="${ARGS[0]:-origin}"
fi

verify_commit() { git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

# empty-tree object hash, used to diff-check root commits
EMPTY_TREE="$(git hash-object -t tree /dev/null)"

# --- push command-line recovery ----------------------------------------------
# Command-line `-c key=value` / `--config-env` entries seen before `push`.
# A separate `git config` process cannot see the ancestor's -c overrides, so
# they are replayed by cfg_get/cfg_get_all below.
PUSH_ARGS=()
PUSH_GLOBAL_CONFIG=()
CANDIDATE_CONFIG=()
PUSH_UNPARSEABLE=0

record_global_config() {
  local kind="$1" raw="$2" name envvar value=""
  if [ "$kind" = "-c" ]; then
    [ -n "$raw" ] && CANDIDATE_CONFIG+=("$raw")
    return
  fi
  # --config-env=<name>=<envvar>: resolve the environment value now.
  case "$raw" in
    *=*) name="${raw%%=*}"; envvar="${raw#*=}" ;;
    *) PUSH_UNPARSEABLE=1; return ;;
  esac
  if [ -n "${!envvar+x}" ]; then
    value="${!envvar}"
  fi
  CANDIDATE_CONFIG+=("$name=$value")
}

# parse_git_push_argv <argv...>: recognize `git [global options] push ...`.
# The global option grammar is parsed rather than assuming `argv[1]` is the
# subcommand, so `git -c k=v push`, `git -C path push` and friends still yield
# the real push arguments. Returns 1 without setting PUSH_ARGS when this is
# not a push; sets PUSH_UNPARSEABLE=1 when it looks like a push but a global
# option is unknown (the caller must then fail, never fall back).
parse_git_push_argv() {
  local -a argv=("$@")
  local n=${#argv[@]} i=1 arg a
  CANDIDATE_CONFIG=()
  while [ "$i" -lt "$n" ]; do
    arg="${argv[$i]}"
    case "$arg" in
      -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--exec-path|--config-env|--attr-source)
        if [ "$arg" = "-c" ] || [ "$arg" = "--config-env" ]; then
          [ $((i + 1)) -lt "$n" ] && record_global_config "$arg" "${argv[$((i + 1))]}"
        fi
        i=$((i + 2)); continue ;;
      -c?*)
        record_global_config -c "${arg#-c}"
        i=$((i + 1)); continue ;;
      -C?*)
        i=$((i + 1)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|--exec-path=*|--attr-source=*)
        i=$((i + 1)); continue ;;
      --config-env=*)
        record_global_config --config-env "${arg#--config-env=}"
        i=$((i + 1)); continue ;;
      --bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--no-lazy-fetch|--no-advice|--paginate|-p|--no-pager|-P|--version|-v|--help|-h|--html-path|--man-path|--info-path)
        i=$((i + 1)); continue ;;
      --)
        i=$((i + 1)); break ;;
      -*)
        # Unknown global option. If a later word is the push subcommand, the
        # command IS a push and must not silently fall back to the current
        # branch; otherwise this is some other git command.
        for a in "${argv[@]:i + 1}"; do
          if [ "$a" = "push" ]; then
            PUSH_UNPARSEABLE=1
            break
          fi
        done
        return 1 ;;
      *)
        if [ "$arg" = "push" ]; then
          PUSH_ARGS=("${argv[@]:i + 1}")
          PUSH_GLOBAL_CONFIG=("${CANDIDATE_CONFIG[@]}")
          return 0
        fi
        return 1 ;;
    esac
  done
  if [ "$i" -lt "$n" ] && [ "${argv[$i]}" = "push" ]; then
    PUSH_ARGS=("${argv[@]:i + 1}")
    PUSH_GLOBAL_CONFIG=("${CANDIDATE_CONFIG[@]}")
    return 0
  fi
  return 1
}

# Walk the /proc ancestor chain looking for the `git push ...` invocation this
# hook (however deeply lefthook nests it) belongs to. Returns 0 and sets
# PUSH_ARGS (array of args after "push") when found.
find_push_args() {
  PUSH_ARGS=()
  PUSH_GLOBAL_CONFIG=()
  PUSH_UNPARSEABLE=0
  local pid self="$BASHPID" argv0 depth=0
  pid="$self"
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$depth" -lt 10 ]; do
    local -a argv=()
    mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || { argv=(); }
    if [ "${#argv[@]}" -ge 1 ]; then
      argv0="${argv[0]##*/}"
      if [ "$argv0" = "git" ]; then
        if parse_git_push_argv "${argv[@]}"; then
          return 0
        fi
        [ "$PUSH_UNPARSEABLE" -eq 1 ] && return 1
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
#   DELETE_ONLY=1    -d/--delete present (deletion publish, no commits)
#   REMOTE_EXPLICIT=1 a remote/--repo was named on the command line
#   SPECS_RELIABLE=1 args were fully understood
parse_push_args() {
  SPECS=()
  WIDE=0
  MIRROR=0
  DELETE_ONLY=0
  SPECS_RELIABLE=1
  REMOTE_EXPLICIT=0
  local -a novalue=(
    -q --quiet -v --verbose -f --force -n --dry-run --all --branches --mirror
    --tags --follow-tags --atomic --no-atomic --porcelain -u --set-upstream
    -t --thin --no-thin -d --delete --no-verify --verify --force-with-lease
    --force-if-includes --no-force-if-includes --signed --no-signed
    --prune --no-prune --progress --no-progress --no-recurse-submodules
    -4 --ipv4 -6 --ipv6
  )
  local -a withvalue=( -o --push-option --receive-pack --exec --repo --server-option --recurse-submodules )
  local arg seen_remote=0 end_options=0 i j known tagprefix
  for ((i = 0; i < ${#PUSH_ARGS[@]}; i++)); do
    arg="${PUSH_ARGS[$i]}"
    if [ "$end_options" -eq 0 ] && [ "$arg" = "--" ]; then
      end_options=1
      continue
    fi
    if [ "$end_options" -eq 0 ] && [[ $arg == -* ]]; then
      case "$arg" in
        --repo=*)
          REMOTE="${arg#--repo=}"
          REMOTE_EXPLICIT=1
          seen_remote=1
          continue ;;
      esac
      known=0
      for j in "${novalue[@]}"; do [ "$arg" = "$j" ] && { known=1; break; }; done
      if [ "$known" -eq 0 ]; then
        for j in "${withvalue[@]}"; do [ "$arg" = "$j" ] && { known=2; break; }; done
      fi
      # combined short flags (e.g. -qu, -fu): fine when every letter is a
      # known value-less option; -oVALUE carries its value inline.
      if [ "$known" -eq 0 ] && [[ $arg =~ ^-[qvfntud]+$ ]]; then
        known=1
        [[ $arg == *d* ]] && DELETE_ONLY=1
      fi
      if [ "$known" -eq 0 ] && [[ $arg == -o?* ]]; then
        known=3
      fi
      case "$arg" in
        --all|--branches|--branches=*|--tags|--follow-tags) WIDE=1 ;;
        --mirror) WIDE=1; MIRROR=1 ;;
        -d|--delete) DELETE_ONLY=1 ;;
      esac
      if [ "$arg" = "--repo" ]; then
        if [ $((i + 1)) -lt "${#PUSH_ARGS[@]}" ]; then
          REMOTE="${PUSH_ARGS[$((i + 1))]}"
          REMOTE_EXPLICIT=1
          seen_remote=1
        fi
      fi
      if [ "$known" -eq 1 ] || [ "$known" -eq 3 ]; then
        :
      elif [ "$known" -eq 2 ]; then
        i=$((i + 1))                  # consume the flag's value
      elif [[ $arg == *=* ]]; then
        :                             # unknown flag with embedded value: keep going
      else
        SPECS_RELIABLE=0              # unknown bare flag: do not trust the rest
      fi
    elif [ "$seen_remote" -eq 0 ]; then
      REMOTE="$arg"                   # first positional is the remote
      REMOTE_EXPLICIT=1
      seen_remote=1
    else
      SPECS+=("$arg")
    fi
  done

  # `git push origin tag v1` is shorthand for refs/tags/v1.
  case "${SPECS[0]:-}" in
    tag|+tag)
      tagprefix=""
      [ "${SPECS[0]:-}" = "+tag" ] && tagprefix="+"
      if [ "${#SPECS[@]}" -ge 2 ]; then
        SPECS=("${tagprefix}refs/tags/${SPECS[1]}" "${SPECS[@]:2}")
      else
        SPECS_RELIABLE=0            # bare `tag` with no tag name
      fi ;;
  esac
}

# --- git config with command-line -c overrides -------------------------------
# cfg_get <key>: last command-line -c value wins, otherwise the repo value.
cfg_get() {
  local key="$1" entry value="" found=0
  for entry in "${PUSH_GLOBAL_CONFIG[@]}"; do
    [ "${entry%%=*}" = "$key" ] || continue
    value="${entry#*=}"
    found=1
  done
  if [ "$found" -eq 1 ]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(git config --get "$key" 2>/dev/null)" || return 1
  printf '%s' "$value"
}

# cfg_get_all <key>: repo values plus command-line -c values (Git appends -c
# entries to multi-valued keys; it does not replace remote.<name>.push).
# A real push also exports -c config through GIT_CONFIG_PARAMETERS, so the
# same value can arrive twice; deduplicate it.
cfg_get_all() {
  local key="$1" entry line
  local -A seen=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -n "${seen[$line]+x}" ] && continue
    seen[$line]=1
    printf '%s\n' "$line"
  done < <(
    git config --get-all "$key" 2>/dev/null || true
    for entry in "${PUSH_GLOBAL_CONFIG[@]}"; do
      [ "${entry%%=*}" = "$key" ] && printf '%s\n' "${entry#*=}"
    done
  )
}

# cfg_get_bool <key>: 0 when the key is set to true or to an unrecognized
# value (conservative: force the wider validation), 1 when unset or
# explicitly false.
cfg_get_bool() {
  local key="$1" value
  value="$(cfg_get "$key")" || return 1
  case "${value,,}" in
    0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

remote_is_configured() {
  local name="$1"
  cfg_get "remote.$name.url" >/dev/null 2>&1 && return 0
  cfg_get "remote.$name.pushurl" >/dev/null 2>&1 && return 0
  cfg_get "remote.$name.push" >/dev/null 2>&1 && return 0
  return 1
}

# Git's default-remote order for a push that names no remote.
resolve_default_remote() {
  local branch c
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
    if c="$(cfg_get "branch.$branch.pushRemote")" && [ -n "$c" ]; then
      REMOTE="$c"
      return 0
    fi
  fi
  if c="$(cfg_get remote.pushDefault)" && [ -n "$c" ]; then
    REMOTE="$c"
    return 0
  fi
  if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
    if c="$(cfg_get "branch.$branch.remote")" && [ -n "$c" ]; then
      REMOTE="$c"
      return 0
    fi
  fi
  # Git's final fallback for a remote-less push is origin. Do not let
  # DUDUDU_PUSH_REMOTE silently redirect a real push whose default differs.
  REMOTE=origin
  return 0
}

# load_config_specs: fill CONFIG_SPECS from remote.<name>.push, including
# command-line -c entries. Only configured remotes have push recipes; a URL
# or path argument falls through to push.default.
CONFIG_SPECS=()
load_config_specs() {
  local line
  CONFIG_SPECS=()
  remote_is_configured "$REMOTE" || return 0
  while IFS= read -r line; do
    [ -n "$line" ] && CONFIG_SPECS+=("$line")
  done < <(cfg_get_all "remote.$REMOTE.push")
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
    # Deletion refspec: the caller prints the note (this function's stdout is
    # captured as the range).
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

# ref_matches_pattern <ref> <pattern>: Git refspec wildcard semantics. The
# single '*' crosses '/' (unlike for-each-ref's FNM_PATHNAME patterns), and
# '?'/'[]' are ordinary characters. Returns 0 match, 1 no match, 2 pattern
# with more than one '*' (outside the grammar this script resolves).
ref_matches_pattern() {
  local ref="$1" pat="$2" prefix suffix
  case "$pat" in
    *'*'*)
      prefix="${pat%%\**}"
      suffix="${pat#*\*}"
      [[ $suffix == *'*'* ]] && return 2
      [[ $ref == "$prefix"*"$suffix" ]]
      ;;
    *) [ "$ref" = "$pat" ] ;;
  esac
}

# Negative push refspecs (^pattern) exclude refs from a wildcard push.
NEGATIVE_PATTERNS=()
is_negative_ref() {
  local ref="$1" pat rc=1
  for pat in "${NEGATIVE_PATTERNS[@]}"; do
    ref_matches_pattern "$ref" "$pat"
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    # rc=2 (multiple '*') is not excluded: validating an extra ref is safe,
    # while guessing the exclusion could under-validate a published ref.
  done
  return 1
}

# append_refspec_ranges <refspec>: append the range(s) this refspec publishes
# to RANGES. Wildcard sources are expanded with for-each-ref and filtered by
# negative refspecs. An unexpandable wildcard or an empty destination is a
# hard failure, never a silent skip.
append_refspec_ranges() {
  local rs="$1" src dst ref prefix suffix mid expdst refs matched=0
  rs="${rs#+}"
  if [[ $rs == *:* ]]; then
    src="${rs%%:*}"
    dst="${rs#*:}"
  else
    src="$rs"
    dst="$rs"
  fi
  if [ -z "$src" ]; then
    note "refspec '$1': deletion publish, no commits to validate"
    return 0
  fi
  if [ -z "$dst" ]; then
    die "refspec '$1' has an empty destination; cannot determine the pushed refs"
  fi
  if [[ $src == *'*'* ]]; then
    if [[ $dst != *'*'* ]]; then
      die "refspec '$1': wildcard source without a wildcard destination"
    fi
    if [[ ${src#*\*} == *'*'* ]]; then
      die "refspec '$1': more than one wildcard is not supported; cannot resolve the published refs"
    fi
    prefix="${src%%\**}"
    suffix="${src#*\*}"
    # Enumerate every ref and apply refspec matching here: for-each-ref's
    # own pattern matching does not let '*' cross '/', while a refspec '*' does.
    if ! refs="$(git for-each-ref --format='%(refname)')"; then
      die "cannot enumerate local refs for wildcard refspec '$1'"
    fi
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      ref_matches_pattern "$ref" "$src" || continue
      is_negative_ref "$ref" && continue
      mid="${ref#"$prefix"}"
      if [ -n "$suffix" ]; then
        mid="${mid%"$suffix"}"
      fi
      expdst="${dst/\*/$mid}"
      RANGES+=("$(refspec_range "$ref:$expdst")")
      matched=1
    done <<< "$refs"
    if [ "$matched" -eq 0 ]; then
      note "refspec '$1': no local refs matched"
    fi
    return 0
  fi
  if is_negative_ref "$src"; then
    note "refspec '$1': excluded by a negative refspec"
    return 0
  fi
  RANGES+=("$(refspec_range "$src:$dst")")
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

# collect_wide: fills RANGES and ROOTS with every local non-merge commit not
# known to be on the remote. Root commits cannot form a base..head range, so
# they are collected separately and validated by message in do_validate.
# --remotes=<name> is rev-list's own ref filter; a literal
# "refs/remotes/<name>/*" argument would not be expanded and would silently
# yield an empty set. Returns 1 (the caller must fail) when rev-list fails.
collect_wide() {
  local mode="${1:-wide}" sha parent commits
  if [ "$mode" = "mirror" ]; then
    # --mirror publishes every ref under refs/ (notes, replace, deploy
    # namespaces, remote-tracking refs), not just branches and tags.
    if ! commits="$(git rev-list --reverse --no-merges --all \
                      --not --remotes="$REMOTE")"; then
      return 1
    fi
  elif ! commits="$(git rev-list --reverse --no-merges --branches --tags \
                      --not --remotes="$REMOTE")"; then
    return 1
  fi
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    if parent="$(git rev-parse --verify --quiet "${sha}^" 2>/dev/null)"; then
      RANGES+=("$parent $sha")
    else
      ROOTS+=("$sha")
    fi
  done <<< "$commits"
}

resolve_wide() {
  local reason="$1" mode="${2:-wide}"
  note "mode=$mode remote=$REMOTE ($reason)"
  ROOTS=()
  if ! collect_wide "$mode"; then
    # Never fail open: an unresolved wide/mirror push must be red.
    die "$mode push: cannot determine the local-only commit set"
  fi
  if [ "${#RANGES[@]}" -eq 0 ] && [ "${#ROOTS[@]}" -eq 0 ]; then
    note "NO_NEW_COMMITS: nothing local is missing from $REMOTE"
  fi
}

# --- resolution ---------------------------------------------------------------
resolve_ranges() {
  RANGES=()
  ROOTS=()
  NEGATIVE_PATTERNS=()
  if [ -n "$RANGE_OVERRIDE_BASE" ]; then
    verify_commit "$RANGE_OVERRIDE_BASE" || die "cannot resolve override base '$RANGE_OVERRIDE_BASE'"
    verify_commit "$RANGE_OVERRIDE_HEAD" || die "cannot resolve override head '$RANGE_OVERRIDE_HEAD'"
    RANGES+=("$RANGE_OVERRIDE_BASE $RANGE_OVERRIDE_HEAD")
    note "mode=override remote=$REMOTE range=$RANGE_OVERRIDE_BASE..$RANGE_OVERRIDE_HEAD"
    return 0
  fi

  if find_push_args; then
    parse_push_args
    if [ "$PUSH_UNPARSEABLE" -eq 1 ]; then
      die "found a git push whose command line could not be parsed; refusing to validate the current branch instead"
    fi
    if [ "$SPECS_RELIABLE" -ne 1 ]; then
      die "cannot parse the git push options (${PUSH_ARGS[*]:-<none>}); refusing to guess which refs are pushed. Verify them with: bash tools/push-range.sh --range <base> <head>"
    fi
    if [ "$REMOTE_EXPLICIT" -eq 0 ]; then
      resolve_default_remote
    fi

    # Command-line --mirror and remote.<name>.mirror both publish every local
    # ref (Git rejects refspecs combined with mirror). Check this before the
    # deletion/wide/spec paths, otherwise a bare mirror push falls back to the
    # current branch and can publish unrelated refs green.
    if [ "$MIRROR" -eq 1 ] || cfg_get_bool "remote.$REMOTE.mirror"; then
      resolve_wide "mirror push: every local ref not on $REMOTE is validated" mirror
      return 0
    fi

    if [ "$DELETE_ONLY" -eq 1 ]; then
      note "mode=delete remote=$REMOTE specs=${SPECS[*]:-<none>}: deletion publish, no commits to validate"
      return 0
    fi
    if [ "$WIDE" -eq 1 ]; then
      resolve_wide "explicit wide push: every local commit not on $REMOTE is validated"
      return 0
    fi

    if [ "${#SPECS[@]}" -eq 0 ]; then
      load_config_specs
      if [ "${#CONFIG_SPECS[@]}" -gt 0 ]; then
        SPECS=("${CONFIG_SPECS[@]}")
        note "mode=configured-refspec remote=$REMOTE specs=${SPECS[*]}"
      fi
    fi

    if [ "${#SPECS[@]}" -gt 0 ]; then
      [ "${#CONFIG_SPECS[@]}" -gt 0 ] ||
        note "mode=refspec remote=$REMOTE specs=${SPECS[*]}"
      local rs
      for rs in "${SPECS[@]}"; do
        case "$rs" in
          ^*) NEGATIVE_PATTERNS+=("${rs#^}") ;;
        esac
      done
      for rs in "${SPECS[@]}"; do
        case "$rs" in
          ^*) continue ;;
        esac
        append_refspec_ranges "$rs"
      done
      return 0
    fi

    # A bare push with no configured refspec: push.default decides.
    local push_default
    push_default="$(cfg_get push.default || true)"
    [ -n "$push_default" ] || push_default=simple
    push_default="${push_default,,}"
    case "$push_default" in
      matching)
        resolve_wide "push.default=matching"
        return 0 ;;
      nothing)
        note "push.default=nothing: no refs would be published"
        return 0 ;;
      simple|current|upstream|tracking)
        ;;                          # fall through to current-branch mode
      *)
        die "unsupported push.default '$push_default'; cannot determine the pushed refs" ;;
    esac
  elif [ "$PUSH_UNPARSEABLE" -eq 1 ]; then
    die "found a git push whose command line could not be parsed; refusing to validate the current branch instead"
  fi

  local out
  out="$(current_branch_range)"
  RANGES+=("$out")
  note "mode=current-branch remote=$REMOTE range=${out% *}"
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
