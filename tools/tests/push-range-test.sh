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
# run_resolver_env KEY=VALUE <args...>
run_resolver_env() {
  local envspec="$1"
  shift
  out="$(cd "$WORK" && env "$envspec" bash tools/push-range.sh "$@" 2>&1)"
  rc=$?
}
# run_git_push_from <dir> <git-args...>: run git from an arbitrary cwd so
# global options such as `-C <repo>` are exercised for real.
run_git_push_from() {
  local dir="$1"
  shift
  out="$(cd "$dir" && git "$@" 2>&1)"
  rc=$?
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
git -C "$WORK" checkout -qb bdel main
commit_empty "docs(repo): deletion probe"
git -C "$WORK" checkout -q main
run_push origin bdel
expect_ok_like "deletion probe branch is published" "PASS: 1 commit\(s\) validated"
run_push -fd origin bdel
expect_ok_like "combined -fd is treated as a deletion" "deletion|no commits to validate"
expect_remote_lacks "combined -fd removes the remote branch" refs/heads/bdel

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
# 13. Git global options before `push` (P1): `git -c ... push` and
#     `git -C ... push` must still validate the ref actually being published,
#     even when the current branch (main) is clean and up to date.
# =============================================================================
git -C "$WORK" checkout -qb optpoison main
commit_empty "feat: invalid commit behind git options"
git -C "$WORK" checkout -q main
run_git_push_from "$WORK" -c gc.auto=0 push origin optpoison
expect_fail_like "git -c before push cannot hide an invalid pushed ref" "expected '<type"
expect_remote_lacks "rejected -c push publishes no branch" refs/heads/optpoison
run_git_push_from "$TMP" -C "$WORK" push origin optpoison
expect_fail_like "git -C before push cannot hide an invalid pushed ref" "expected '<type"
expect_remote_lacks "rejected -C push publishes no branch" refs/heads/optpoison
mkdir -p "$WORK/hooks"
cp "$WORK/.git/hooks/pre-push" "$WORK/hooks/pre-push"
chmod +x "$WORK/hooks/pre-push"
run_git_push_from "$WORK" -c core.hooksPath=hooks push origin optpoison
expect_fail_like "git -c core.hooksPath push still validates the pushed ref" "expected '<type"
expect_remote_lacks "custom-hook-path push publishes no branch" refs/heads/optpoison

git -C "$WORK" checkout -qb optok main
commit_empty "docs(repo): option-prefixed valid push"
git -C "$WORK" checkout -q main
run_git_push_from "$WORK" -c gc.auto=0 push origin optok
expect_ok_like "git -c push still validates and publishes a valid ref" "PASS: 1 commit\(s\) validated"
expect_remote_has "option-prefixed valid push reaches the remote" refs/heads/optok

# =============================================================================
# 14. Configured push refspec (P1): bare `git push` with remote.<name>.push,
#     and a command-line -c override, must validate the configured refs.
# =============================================================================
git -C "$WORK" checkout -qb cfgpoison main
commit_empty "feat: invalid commit behind configured refspec"
git -C "$WORK" checkout -q main
git -C "$WORK" config remote.origin.push refs/heads/cfgpoison:refs/heads/cfgpoison
run_push origin
expect_fail_like "remote.<name>.push refspec is validated" "expected '<type"
expect_remote_lacks "rejected configured push publishes no branch" refs/heads/cfgpoison
run_push
expect_fail_like "bare git push honors remote.<name>.push" "expected '<type"
expect_remote_lacks "rejected bare configured push publishes no branch" refs/heads/cfgpoison
git -C "$WORK" config --unset-all remote.origin.push
run_git_push_from "$WORK" -c remote.origin.push=refs/heads/cfgpoison:refs/heads/cfgpoison push origin
expect_fail_like "command-line -c remote.<name>.push is honored" "expected '<type"
expect_remote_lacks "rejected -c configured push publishes no branch" refs/heads/cfgpoison

git -C "$WORK" checkout -qb cfgok main
commit_empty "docs(repo): configured-recipe valid content"
git -C "$WORK" checkout -q main
git -C "$WORK" config remote.origin.push refs/heads/cfgok:refs/heads/cfgok
run_push origin
expect_ok_like "configured refspec validates and publishes a valid ref" "PASS: 1 commit\(s\) validated"
expect_remote_has "configured push reaches the remote" refs/heads/cfgok
git -C "$WORK" config --unset-all remote.origin.push
run_push origin main
expect_ok_like "after unsetting the refspec main is NO_NEW_COMMITS" "NO_NEW_COMMITS"

# =============================================================================
# 15. Wildcard refspecs and negative exclusions are resolved from local refs.
# =============================================================================
git -C "$WORK" checkout -qb wildbad main
commit_empty "feat: invalid commit under a wildcard"
git -C "$WORK" checkout -qb wildok main
commit_empty "docs(repo): valid wildcard content"
git -C "$WORK" checkout -q main
run_push origin 'refs/heads/wild*:refs/heads/wild*'
expect_fail_like "wildcard push validates every matched ref" "expected '<type"
expect_remote_lacks "rejected wildcard push publishes no valid branch" refs/heads/wildok
expect_remote_lacks "rejected wildcard push publishes no invalid branch" refs/heads/wildbad
run_push origin 'refs/heads/wild*:refs/heads/wild*' '^refs/heads/wildbad'
expect_ok_like "negative refspec excludes the invalid branch from the wildcard" "PASS: 1 commit\(s\) validated"
expect_remote_has "negative refspec still publishes the valid branch" refs/heads/wildok
expect_remote_lacks "negative refspec does not publish the excluded branch" refs/heads/wildbad

# A refspec '*' crosses '/' (for-each-ref's own globs do not). Only the
# slash-named branch is invalid, so a resolver that misses it goes green.
git -C "$WORK" checkout -qb slashok main
commit_empty "docs(repo): slash wildcard valid content"
git -C "$WORK" branch slash/bad "$(git -C "$WORK" rev-parse cfgpoison)"
git -C "$WORK" checkout -q main
run_push origin 'refs/heads/slash*:refs/heads/slash*'
expect_fail_like "wildcard '*' crosses '/' like Git refspecs" "expected '<type"
expect_remote_lacks "slash-crossing wildcard publishes no invalid ref" refs/heads/slash/bad
expect_remote_lacks "slash-crossing wildcard publishes no valid ref on rejection" refs/heads/slashok

# =============================================================================
# 16. Mirror pushes validate every local ref namespace, not just heads/tags.
# =============================================================================
invalid_ref_sha="$(git -C "$WORK" rev-parse cfgpoison)"
git -C "$WORK" update-ref refs/deploy/invalid "$invalid_ref_sha"
git -C "$WORK" branch -qD optpoison cfgpoison wildbad widebad slash/bad
mirror_before="$(git --git-dir="$REMOTE" rev-parse refs/heads/main)"
run_push --mirror origin
expect_fail_like "mirror push validates refs outside branches and tags" "expected '<type"
expect_remote_lacks "rejected mirror push publishes no deploy ref" refs/deploy/invalid
git -C "$WORK" config remote.origin.mirror true
run_push origin
expect_fail_like "remote.<name>.mirror bare push validates every local ref" "expected '<type"
expect_remote_lacks "rejected configured mirror publishes no deploy ref" refs/deploy/invalid
git -C "$WORK" config --unset remote.origin.mirror
run_git_push_from "$WORK" -c remote.origin.mirror=true push origin
expect_fail_like "command-line -c remote.<name>.mirror is honored" "expected '<type"
expect_remote_lacks "rejected -c mirror publishes no deploy ref" refs/deploy/invalid
if [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/main)" = "$mirror_before" ]; then
  report_pass "rejected mirror pushes leave the remote main tip unchanged"
else
  report_fail "rejected mirror pushes leave the remote main tip unchanged"
fi

# =============================================================================
# 17. Space-separated --recurse-submodules consumes its value (not the remote).
# =============================================================================
git -C "$WORK" checkout -qb rsok main
commit_empty "docs(repo): recurse-submodules option value"
git -C "$WORK" checkout -q main
run_git_push_from "$WORK" push --recurse-submodules no origin rsok
expect_ok_like "space-separated --recurse-submodules consumes its value" "mode=refspec remote=origin specs=rsok"
expect_remote_has "recurse-submodules push publishes the real target" refs/heads/rsok

# =============================================================================
# 18. Path-aware build trigger (P2): benchmark sources count, docs do not;
#     DUDUDU_FORCE_BUILD_GATE=1 forces the build for a docs-only range.
# =============================================================================
git -C "$WORK" checkout -qb benchchange main
mkdir -p "$WORK/benchmarks"
printf 'int benchmark_probe = 1;\n' > "$WORK/benchmarks/probe.cpp"
git -C "$WORK" add benchmarks/probe.cpp
git -C "$WORK" commit -q -m "perf(bench): add a benchmark probe"
git -C "$WORK" checkout -q main
run_resolver relevant --range main benchchange
expect_ok_like "benchmark changes trigger the build gate" "benchmarks/probe.cpp"

git -C "$WORK" checkout -qb docschange main
mkdir -p "$WORK/docs"
printf '# note\n' > "$WORK/docs/note.md"
git -C "$WORK" add docs/note.md
git -C "$WORK" commit -q -m "docs(repo): add a note"
git -C "$WORK" checkout -q main
run_resolver relevant --range main docschange
expect_fail_like "docs-only changes skip the build gate" "only non-build paths"
run_resolver_env DUDUDU_FORCE_BUILD_GATE=1 relevant --range main docschange
expect_ok_like "forced full gate builds docs-only ranges" "DUDUDU_FORCE_BUILD_GATE"

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
