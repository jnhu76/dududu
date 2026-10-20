#!/usr/bin/env bash
# Scenario tests for tools/push-range.sh — the push-set resolver.
#
# Hermetic: a scratch work repo, a local bare remote, and a plain git
# pre-push hook that calls the resolver (no lefthook dependency, so the suite
# runs anywhere git does). Covers the shapes that matter for "never a silent
# green":
#
#   first push, tracked push, empty push (NO_NEW_COMMITS), invalid commit
#   rejection, force push, multi-ref push, deletion (flag and refspec form),
#   missing remote baseline (hard fail), and wide pushes (--all) carrying a
#   root commit or another branch's invalid commit.
#
# Usage: bash tools/tests/push-range-test.sh
# Requirements: bash, git. No network; writes only under $(mktemp -d).

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export LC_ALL=C.UTF-8

pass=0
fail=0
failures=()

report_pass() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
report_fail() {
  fail=$((fail + 1))
  failures+=("$1")
  printf 'FAIL %s\n' "$1"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dududu-push-range-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

WORK="$TMP/work"
REMOTE="$TMP/remote.git"
REMOTE2="$TMP/remote2.git"

if [ ! -f "$TOOLS_DIR/push-range.sh" ] || [ ! -f "$TOOLS_DIR/check-commit.sh" ]; then
  printf 'RED: tools/push-range.sh or tools/check-commit.sh missing under %s\n' "$TOOLS_DIR"
  exit 1
fi

git init -q -b main "$WORK"
git -C "$WORK" config user.email push-range-test@dududu.local
git -C "$WORK" config user.name "push-range test"
git -C "$WORK" config commit.gpgsign false
cp -R "$TOOLS_DIR" "$WORK/tools"
cat > "$WORK/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
exec bash tools/push-range.sh validate
HOOK
chmod +x "$WORK/.git/hooks/pre-push"
git init -q --bare "$REMOTE"
git init -q --bare "$REMOTE2"
git -C "$WORK" remote add origin "$REMOTE"
git -C "$WORK" remote add remote2 "$REMOTE2"

out=""
rc=0
# run_push <args...>: run git push from the work repo, capture output + status.
run_push() {
  out="$(cd "$WORK" && git push "$@" 2>&1)"
  rc=$?
}
# run_resolver <args...>
run_resolver() {
  out="$(cd "$WORK" && bash tools/push-range.sh "$@" 2>&1)"
  rc=$?
}
expect_ok() {
  local name="$1"
  if [ "$rc" -eq 0 ]; then
    report_pass "$name"
  else
    report_fail "$name (expected exit 0, got $rc)"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}
expect_ok_like() {
  local name="$1" pattern="$2"
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
expect_fail_like() {
  local name="$1" pattern="$2"
  if [ "$rc" -eq 0 ]; then
    report_fail "$name (expected nonzero exit, got 0)"
    printf '%s\n' "$out" | sed 's/^/     | /'
  elif ! printf '%s\n' "$out" | grep -Eiq "$pattern"; then
    report_fail "$name (failed as expected, but output lacks /$pattern/)"
    printf '%s\n' "$out" | sed 's/^/     | /'
  else
    report_pass "$name"
  fi
}
expect_remote_has() {
  local name="$1" ref="$2" dir="${3:-$REMOTE}"
  if git --git-dir="$dir" rev-parse --verify --quiet "$ref" >/dev/null; then
    report_pass "$name"
  else
    report_fail "$name (remote lacks $ref)"
  fi
}
expect_remote_lacks() {
  local name="$1" ref="$2" dir="${3:-$REMOTE}"
  if git --git-dir="$dir" rev-parse --verify --quiet "$ref" >/dev/null; then
    report_fail "$name (remote unexpectedly has $ref)"
  else
    report_pass "$name"
  fi
}

commit_empty() { git -C "$WORK" commit -q --allow-empty -m "$1"; }

# =============================================================================
# Bootstrap: main pushed with the hook bypassed (no baseline exists yet —
# the documented bootstrapping exception).
# =============================================================================
commit_empty "chore(repo): bootstrap"
run_push --no-verify -q origin main
if [ "$rc" -ne 0 ]; then
  printf 'RED: cannot bootstrap the scratch remote\n%s\n' "$out"
  exit 1
fi
git -C "$WORK" fetch -q origin

# =============================================================================
# 1. First push of a new branch: baseline via merge-base with origin/main.
# =============================================================================
git -C "$WORK" checkout -qb feat-a
commit_empty "feat(adapter): add the first probe"
run_push origin feat-a
expect_ok_like "first push validates the carried commits (refspec mode)" "mode=refspec"
expect_remote_has "first push reaches the remote" refs/heads/feat-a

# =============================================================================
# 2. Tracked push: only the new commit is validated.
# =============================================================================
commit_empty "fix(sdk): tracked push probe"
run_push origin feat-a
expect_ok_like "tracked push validates against the tracking ref" "PASS: 1 commit\(s\) validated"
expect_remote_has "tracked push reaches the remote" refs/heads/feat-a

# =============================================================================
# 3. Empty push: explicit NO_NEW_COMMITS, still green.
# =============================================================================
run_push origin feat-a
expect_ok_like "empty push is explicit NO_NEW_COMMITS" "NO_NEW_COMMITS"

# =============================================================================
# 4. Invalid commit in the pushed range: rejected, remote unchanged.
# =============================================================================
before_tip="$(git --git-dir="$REMOTE" rev-parse refs/heads/feat-a)"
commit_empty "feat: missing scope must be rejected"
run_push origin feat-a
expect_fail_like "invalid commit in the pushed range is rejected" "expected '<type>"
if [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/feat-a)" = "$before_tip" ]; then
  report_pass "rejected push leaves the remote tip unchanged"
else
  report_fail "rejected push leaves the remote tip unchanged"
fi

# =============================================================================
# 5. Force push of a rewritten (valid) commit passes.
# =============================================================================
git -C "$WORK" commit -q --amend --allow-empty -m "feat(adapter): rewrite the probe"
run_push --force origin feat-a
expect_ok_like "force push of a valid rewrite passes" "PASS: 1 commit\(s\) validated"

# =============================================================================
# 6. Multi-ref push: every refspec's commits are validated.
# =============================================================================
git -C "$WORK" checkout -qb b1 main
commit_empty "docs(repo): b1 content"
git -C "$WORK" checkout -qb b2 main
commit_empty "docs(repo): b2 content"
git -C "$WORK" checkout -q main
run_push origin b1 b2
expect_ok_like "multi-ref push validates both refspecs" "specs=b1 b2"
if [ "$(printf '%s\n' "$out" | grep -Ec 'PASS: [0-9]+ commit\(s\) validated')" -ge 2 ]; then
  report_pass "multi-ref push validates each range separately"
else
  report_fail "multi-ref push validates each range separately"
  printf '%s\n' "$out" | sed 's/^/     | /'
fi
expect_remote_has "multi-ref push reaches b1" refs/heads/b1
expect_remote_has "multi-ref push reaches b2" refs/heads/b2

# an invalid commit on ONE refspec blocks the whole multi-ref push
git -C "$WORK" checkout -qb b3 main
commit_empty "feat: invalid commit on b3"
git -C "$WORK" checkout -q main
run_push origin b1 b3
expect_fail_like "one invalid refspec blocks the multi-ref push" "expected '<type>"
expect_remote_lacks "blocked multi-ref push publishes nothing" refs/heads/b3
git -C "$WORK" branch -qD b3

# =============================================================================
# 7. Deletions: flag and refspec form, with unrelated invalid local commits
#    present (deletions publish no commits and must not re-validate trivia).
# =============================================================================
git -C "$WORK" checkout -qb poison main
commit_empty "feat: unrelated invalid local commit"
git -C "$WORK" checkout -q main
run_push origin --delete b1
expect_ok_like "deletion via --delete publishes no commits" "deletion|no commits to validate"
expect_remote_lacks "--delete removes the remote branch" refs/heads/b1
run_push origin :b2
expect_ok_like "deletion via refspec publishes no commits" "deletes|no commits to validate"
expect_remote_lacks "refspec deletion removes the remote branch" refs/heads/b2
git -C "$WORK" branch -qD poison
git -C "$WORK" branch -qD b1

# =============================================================================
# 8. Missing baseline: a brand-new remote with no refs must fail hard.
# =============================================================================
run_push remote2 main
expect_fail_like "missing baseline fails hard (never NO_NEW_COMMITS)" "cannot determine the push base"
if printf '%s\n' "$out" | grep -Eiq "NO_NEW_COMMITS"; then
  report_fail "missing baseline does not masquerade as an empty range"
else
  report_pass "missing baseline does not masquerade as an empty range"
fi
expect_remote_lacks "failed baseline push publishes nothing" refs/heads/main "$REMOTE2"

# =============================================================================
# 9. Wide push (--all) carrying an invalid root commit: must be rejected,
#    not reported as nothing-to-do (regression for the fail-open blocker).
# =============================================================================
git -C "$WORK" checkout -q -B widemain main
# shellcheck disable=SC1083  # ^{tree} is git syntax, not shell
root_invalid="$(cd "$WORK" && git commit-tree "$(git rev-parse main^{tree})" -m "feat: invalid orphan root commit")"
git -C "$WORK" update-ref refs/heads/orphan "$root_invalid"
run_push --all origin
expect_fail_like "wide push validates an invalid root commit by message" "expected '<type>"
if printf '%s\n' "$out" | grep -Eiq "NO_NEW_COMMITS"; then
  report_fail "wide push with an invalid root is not reported as NO_NEW_COMMITS"
else
  report_pass "wide push with an invalid root is not reported as NO_NEW_COMMITS"
fi
expect_remote_lacks "rejected wide push publishes no orphan branch" refs/heads/orphan

# =============================================================================
# 10. Wide push (--all) with a VALID root commit passes.
# =============================================================================
# shellcheck disable=SC1083  # ^{tree} is git syntax, not shell
root_valid="$(cd "$WORK" && git commit-tree "$(git rev-parse main^{tree})" -m "chore(repo): valid orphan root commit")"
git -C "$WORK" update-ref refs/heads/orphan "$root_valid"
run_push --all origin
expect_ok_like "wide push accepts a valid root commit" "mode=wide"
expect_remote_has "valid wide push publishes the orphan branch" refs/heads/orphan

# =============================================================================
# 11. Wide push (--all) with an invalid non-root commit on another branch.
# =============================================================================
git -C "$WORK" checkout -qb widebad main
commit_empty "feat: wide invalid commit"
git -C "$WORK" checkout -q widemain
run_push --all origin
expect_fail_like "wide push validates non-root commits from other branches" "expected '<type>"
expect_remote_lacks "rejected wide push does not publish widebad" refs/heads/widebad

# =============================================================================
# 12. Explicit --range override still works (manual escape hatch).
# =============================================================================
git -C "$WORK" checkout -q widemain
commit_empty "chore(repo): override probe"
run_resolver validate --range main widemain
expect_ok_like "explicit --range override validates the given range" "PASS: 1 commit\(s\) validated"
run_resolver validate --range main widemain --nonsense-flag
expect_fail_like "unknown resolver arguments are usage errors" "usage:"

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
