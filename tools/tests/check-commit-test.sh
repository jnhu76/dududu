#!/usr/bin/env bash
# Negative-first test suite for tools/check-commit.sh.
#
# Written before the checker itself (R0.1 review protocol): every case here is
# a contract the checker must satisfy, and the suite is designed so that a
# missing OR permissive checker cannot produce a green run — invalid-message
# cases expect a nonzero exit, so a stub that always exits 0 fails the suite.
#
# Usage:
#   bash tools/tests/check-commit-test.sh
# Override the checker under test (used to prove the suite rejects a stub):
#   CHECK_COMMIT=/path/to/stub bash tools/tests/check-commit-test.sh
#
# Requirements: bash, git. No network, no writes outside $(mktemp -d).

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${CHECK_COMMIT:-$SCRIPT_DIR/../check-commit.sh}"
export LC_ALL=C.UTF-8

pass=0
fail=0
failures=()
TEST_CWD=""

report_pass() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
report_fail() {
  fail=$((fail + 1))
  failures+=("$1")
  printf 'FAIL %s\n' "$1"
}

run_checker() {
  if [ -n "$TEST_CWD" ]; then
    (cd "$TEST_CWD" && "$CHECKER" "$@" 2>&1)
  else
    "$CHECKER" "$@" 2>&1
  fi
}

# expect_pass <name> <checker args...>
expect_pass() {
  local name="$1"; shift
  local out rc
  out=$(run_checker "$@")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    report_pass "$name"
  else
    report_fail "$name (expected exit 0, got $rc)"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# expect_fail <name> <checker args...>
expect_fail() {
  local name="$1"; shift
  local out rc
  out=$(run_checker "$@")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    report_pass "$name"
  else
    report_fail "$name (expected nonzero exit, got 0)"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# expect_fail_like <name> <grep -E pattern> <checker args...>
expect_fail_like() {
  local name="$1" pattern="$2"; shift 2
  local out rc
  out=$(run_checker "$@")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    report_fail "$name (expected nonzero exit, got 0)"
  elif ! printf '%s\n' "$out" | grep -Eiq "$pattern"; then
    report_fail "$name (failed as expected, but output lacks /$pattern/)"
    printf '%s\n' "$out" | sed 's/^/     | /'
  else
    report_pass "$name"
  fi
}

# expect_pass_like <name> <grep -E pattern> <checker args...>
expect_pass_like() {
  local name="$1" pattern="$2"; shift 2
  local out rc
  out=$(run_checker "$@")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    report_fail "$name (expected exit 0, got $rc)"
    printf '%s\n' "$out" | sed 's/^/     | /'
  elif ! printf '%s\n' "$out" | grep -Eiq "$pattern"; then
    report_fail "$name (passed, but output lacks /$pattern/)"
    printf '%s\n' "$out" | sed 's/^/     | /'
  else
    report_pass "$name"
  fi
}

# --- scratch repository helpers ----------------------------------------------

new_repo() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/dududu-commit-test.XXXXXX")
  git init -q -b main "$dir"
  git -C "$dir" config user.email test@dududu.local
  git -C "$dir" config user.name "dududu test"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" commit -q --allow-empty -m "chore(repo): bootstrap test repo"
  printf '%s' "$dir"
}

write_msg() { printf '%s' "$2" > "$1"; }

# =============================================================================
# Precondition: the checker must exist. A missing checker is itself the RED
# state this negative-first suite starts from.
# =============================================================================
if [ ! -f "$CHECKER" ]; then
  printf 'RED: checker not found at %s\n' "$CHECKER"
  printf '     implement tools/check-commit.sh to satisfy this suite\n'
  exit 1
fi

# =============================================================================
# --message mode: valid headers
# =============================================================================
expect_pass "msg: feat"        --message "feat(adapter): add native filesystem wrapper"
expect_pass "msg: fix"         --message "fix(sdk): prevent stale archive reuse"
expect_pass "msg: perf"        --message "perf(uring): reduce completion dispatch cost"
expect_pass "msg: refactor"    --message "refactor(oracle): split result comparison from io capture"
expect_pass "msg: test"        --message "test(oracle): detect bypassed filesystem reads"
expect_pass "msg: build"       --message "build(cmake): isolate SDK build profiles"
expect_pass "msg: ci"          --message "ci(repo): add lightweight policy validation"
expect_pass "msg: docs"        --message "docs(bench): describe benchmark admission"
expect_pass "msg: chore"       --message "chore(repo): configure lefthook"
expect_pass "msg: revert"      --message "revert(adapter): restore direct read path"
expect_pass "msg: breaking bang" --message "feat(sdk)!: restructure SDK layout"
expect_pass "msg: digit subject" --message "fix(duckdb): 3x slower scan fixed by cache pinning"
expect_pass "msg: hyphen scope"  --message "feat(native-wrapper): add adapter shim"
expect_pass "msg: breaking with body" --message "$(printf 'feat(sdk)!: restructure SDK layout\n\nThe installed prefix moves from lib/ to lib64/.\n\nBREAKING CHANGE: consumers must re-run the sync step.')"
expect_pass "msg: body without footer" --message "$(printf 'fix(adapter): clamp read size to segment\n\nRefs #12')"
expect_pass "msg: exactly 72 chars" --message "feat(uring): x x x x x x x x x x x x x x x x x x x x x x x x x x x x 599"

# =============================================================================
# --message mode: invalid headers (the negative core of this suite)
# =============================================================================
expect_fail_like "msg: unknown type"        "type|allowed" --message "foo(repo): add thing"
expect_fail_like "msg: typo type"           "type|allowed" --message "featx(repo): add thing"
expect_fail_like "msg: uppercase type"      "type|allowed" --message "Feat(repo): add thing"
expect_fail_like "msg: missing scope"       "scope"        --message "feat: add thing"
expect_fail_like "msg: missing scope breaking" "scope"     --message "feat!: add thing"
expect_fail_like "msg: empty scope"         "scope"        --message "feat(): add thing"
expect_fail_like "msg: combined type space" "type|allowed" --message "ci feat: add thing"
expect_fail_like "msg: combined type slash" "type|allowed" --message "chore/fix(repo): add thing"
expect_fail_like "msg: combined type plus"  "type|allowed" --message "test+fix(repo): add thing"
expect_fail_like "msg: forbidden scope r0"       "scope"   --message "feat(r0): add thing"
expect_fail_like "msg: forbidden scope d2"       "scope"   --message "feat(d2): add thing"
expect_fail_like "msg: forbidden scope d0"       "scope"   --message "docs(d0): add thing"
expect_fail_like "msg: forbidden scope phase-1"  "scope"   --message "docs(phase-1): add thing"
expect_fail_like "msg: forbidden scope stage-2"  "scope"   --message "chore(stage-2): add thing"
expect_fail_like "msg: forbidden scope round-3"  "scope"   --message "test(round-3): add thing"
expect_fail_like "msg: forbidden scope phase1"   "scope"   --message "docs(phase1): add thing"
expect_fail_like "msg: forbidden scope stage0"   "scope"   --message "chore(stage0): add thing"
expect_fail_like "msg: forbidden scope r0a"      "scope"   --message "feat(r0a): add thing"
expect_fail_like "msg: forbidden scope r-0"      "scope"   --message "feat(r-0): add thing"
expect_fail_like "msg: uppercase scope"     "scope"        --message "feat(Repo): add thing"
expect_fail_like "msg: underscore scope"    "scope"        --message "feat(native_wrapper): add thing"
expect_fail_like "msg: leading hyphen scope"   "scope"     --message "feat(-repo): add thing"
expect_fail_like "msg: trailing hyphen scope"  "scope"     --message "feat(repo-): add thing"
expect_fail_like "msg: double hyphen scope"    "scope"     --message "feat(re--po): add thing"
expect_fail_like "msg: digit-leading scope is kebab-ok but phase-like r1 banned" "scope" --message "feat(r1): add thing"
expect_fail_like "msg: empty subject"       "subject"      --message "feat(repo):"
expect_fail_like "msg: colon missing"       "type|allowed" --message "feat(repo) add thing"
expect_fail_like "msg: uppercase subject"   "subject"      --message "feat(repo): Add thing"
expect_fail_like "msg: trailing period"     "period|subject" --message "feat(repo): add thing."
expect_fail_like "msg: trailing full stop"  "period|subject" --message "feat(repo): 加个功能。"
expect_fail_like "msg: double space subject"   "subject"   --message "feat(repo):  add thing"
expect_fail_like "msg: trailing whitespace"    "whitespace|subject" --message "feat(repo): add thing "
expect_fail_like "msg: leading whitespace header" "whitespace|type|allowed" --message " feat(repo): add thing"
expect_fail_like "msg: header over 72"      "72|length"    --message "feat(repo): x x x x x x x x x x x x x x x x x x x x x x x x x x x x x 600"
expect_fail_like "msg: empty message"       "empty"        --message ""
expect_fail_like "msg: whitespace-only message" "empty"    --message "   "
expect_fail_like "msg: newline-only message"    "empty"    --message "$(printf '\n\n\n')"
expect_fail_like "msg: valid decoy in body cannot rescue bad header" "type|allowed" \
  --message "$(printf 'not a conventional header\nfeat(repo): decoy')"
expect_fail_like "msg: valid decoy cannot rescue trailing period" "period|subject" \
  --message "$(printf 'feat(repo): bad period.\nfeat(repo): decoy')"
expect_fail_like "msg: control character"   "text|control" --message "$(printf 'feat(repo): add \x01 thing')"
expect_fail_like "msg: trailing carriage return" "carriage|whitespace" --message "$(printf 'feat(repo): add thing\r')"
expect_fail_like "msg: embedded carriage return" "carriage" --message "$(printf 'feat(repo): add a\rcarriage return inside')"
expect_fail_like "msg: label appears in diagnostics" "PR title" --label "PR title" --message "feat: no scope"

# =============================================================================
# --file mode (the commit-msg hook path)
# =============================================================================
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/dududu-commit-test-files.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

write_msg "$tmpdir/valid-with-comments.msg" \
"# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored.
feat(adapter): add native filesystem wrapper

Body text survives untouched.

BREAKING CHANGE: none here, just a footer example.
"
expect_pass "file: comments and body" --file "$tmpdir/valid-with-comments.msg"

write_msg "$tmpdir/leading-blank.msg" \
"
chore(repo): configure lefthook
"
expect_pass "file: leading blank line tolerated" --file "$tmpdir/leading-blank.msg"

# whitespace-only leading line generated programmatically: the suite itself
# must stay free of trailing whitespace for the pre-commit gate
printf '   \nchore(repo): configure lefthook\n' > "$tmpdir/leading-whitespace.msg"
expect_pass "file: whitespace-only leading line tolerated" --file "$tmpdir/leading-whitespace.msg"

write_msg "$tmpdir/invalid-first-line.msg" \
"# comment
feat: no scope here
"
expect_fail_like "file: invalid first content line" "scope" --file "$tmpdir/invalid-first-line.msg"

: > "$tmpdir/empty.msg"
expect_fail_like "file: empty file" "empty" --file "$tmpdir/empty.msg"

write_msg "$tmpdir/comments-only.msg" \
"# Please enter the commit message for your changes.
# Lines starting with '#' will be ignored.
"
expect_fail_like "file: comments-only file" "empty" --file "$tmpdir/comments-only.msg"

printf 'feat(repo): add thing\r\nbody\r\n' > "$tmpdir/crlf.msg"
expect_fail_like "file: CRLF message rejected with hint" "carriage" --file "$tmpdir/crlf.msg"

printf 'feat(repo): add thing\0hidden line\n' > "$tmpdir/nul.msg"
expect_fail_like "file: NUL byte rejected" "text|control" --file "$tmpdir/nul.msg"

expect_fail_like "file: missing file" "cannot|read|exist|open" --file "$tmpdir/does-not-exist.msg"

# =============================================================================
# --self-test: the checker must refute itself
# =============================================================================
expect_pass_like "self-test: passes and counts cases" "self-test" --self-test

# =============================================================================
# --range mode: scratch repositories
# Every git call below is routed into the scratch repo with git -C: nothing in
# this suite may ever touch the repository the suite itself lives in.
# Ranges are anchored on captured SHAs, never on positional main~N, so the
# cases stay valid as the scratch history grows.
# =============================================================================
TEST_CWD=$(new_repo)
scratch() { git -C "$TEST_CWD" "$@"; }
base_sha=$(scratch rev-parse --short=12 HEAD)   # valid bootstrap commit
scratch commit -q --allow-empty -m "feat(adapter): add native filesystem wrapper"
scratch commit -q --allow-empty -m "fix(sdk): prevent stale archive reuse"
two_valid_sha=$(scratch rev-parse --short=12 HEAD)
expect_pass_like "range: two valid commits" "PASS" --range "$base_sha" "$two_valid_sha"
expect_pass_like "range: empty range is explicit NO_NEW_COMMITS" "NO_NEW_COMMITS" --range main main
expect_pass_like "range: empty range via identical endpoints" "NO_NEW_COMMITS" --range "$base_sha" "$base_sha"

# an invalid commit BEFORE a merge must not be masked by merge skipping
scratch commit -q --allow-empty -m "feat: invalid commit missing scope"
scratch checkout -qb side
scratch commit -q --allow-empty -m "test(oracle): detect bypassed filesystem reads"
scratch checkout -q main
scratch merge -q --no-ff side -m "Merge pull request #99 from jnhu76/side"
merge_sha=$(scratch rev-parse --short=12 HEAD)
expect_pass_like "range: merge commit skipped explicitly" "skip.*merge|merge.*skip" --range "${merge_sha}^1" "$merge_sha"
expect_fail_like "range: merge skip does not hide an earlier bad commit" "missing scope" --range "$base_sha" "$merge_sha"

# one invalid commit among valid ones must fail and name the culprit
scratch commit -q --allow-empty -m "feat(repo): good commit after merge"
scratch commit -q --allow-empty -m "feat(repo): bad subject here."
bad_sha=$(scratch rev-parse --short=12 HEAD)
expect_fail_like "range: one bad commit fails the range" "bad subject here\." --range "$two_valid_sha" main
expect_fail_like "range: failure names the offending sha" "$bad_sha" --range "$two_valid_sha" main

# empty subject commit is caught
scratch commit -q --allow-empty --allow-empty-message -m ""
expect_fail_like "range: empty commit subject fails" "empty" --range main~1 main

# raw first line is validated, not the %s-joined subject
scratch commit -q --allow-empty --cleanup=verbatim -F - <<'MSG'
feat(repo): this first line ends with a period.
continuation line that %s-joining would hide
MSG
expect_fail_like "range: wrapped raw first line validated verbatim" "period|subject" --range main~1 main

# an invalid LAST commit is caught too (guards against dropped final lines)
scratch commit -q --allow-empty -m "feat: last commit without scope"
expect_fail_like "range: invalid last commit caught" "scope" --range main~1 main

# breaking-change body/footers pass through ranges
scratch commit -q --allow-empty -m "$(printf 'feat(sdk)!: restructure SDK layout\n\nBREAKING CHANGE: prefix layout moved.')"
expect_pass "range: breaking commit with footer" --range main~1 main

# nonexistent refs must fail, never pass
expect_fail_like "range: nonexistent base" "cannot resolve|unknown revision" --range no-such-ref main
expect_fail_like "range: nonexistent head" "cannot resolve|unknown revision" --range main no-such-ref
expect_fail_like "range: nonexistent full sha base" "cannot resolve|unknown revision" --range 0000000000000000000000000000000000000000 main

# range diagnostics name the offending range
expect_fail_like "range: diagnostics name the range" "main~2\.\.main" --range main~2 main

# git-generated merge messages are exempt only while MERGE_HEAD exists
write_msg "$tmpdir/merge.msg" "Merge branch 'side' into main
"
scratch rev-parse HEAD > "$TEST_CWD/.git/MERGE_HEAD"
expect_pass "file: git-generated merge message accepted during a merge" --file "$tmpdir/merge.msg"
rm -f "$TEST_CWD/.git/MERGE_HEAD"
expect_fail_like "file: merge-looking message rejected without a merge in progress" "expected '<type>" --file "$tmpdir/merge.msg"

# usage errors
expect_fail "usage: no arguments"
expect_fail "usage: unknown flag" --nonsense
expect_fail "usage: --range with one arg" --range main

rm -rf "$TEST_CWD"
TEST_CWD=""

# =============================================================================
# summary
# =============================================================================
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'SUITE FAIL — failing cases:\n'
  printf '%s\n' "${failures[@]}" | sed 's/^/  - /'
  exit 1
fi
printf 'SUITE PASS (%d cases)\n' "$pass"
exit 0
