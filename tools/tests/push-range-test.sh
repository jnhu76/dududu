#!/usr/bin/env bash
# Scenario tests for tools/push-range.sh — the push-set resolver.
#
# Hermetic: a scratch work repo, a local bare remote, and a plain git
# pre-push hook that calls the resolver (no lefthook dependency, so the suite
# runs anywhere git does). The hook forwards Git's official pre-push stream,
# which is what the resolver consumes in a real push.
#
# Covers the shapes that matter for "never a silent green":
#   first push (new ref, full-history validation), tracked push, empty push
#   (NO_NEW_COMMITS), invalid commit rejection, force push, multi-ref push,
#   deletion (flag and refspec form), a brand-new remote, wide pushes
#   (--all) with a root or another branch's invalid commit, matching
#   refspecs (':' and '+:'), mirror pushes including remote-tracking refs,
#   wildcard/negative refspecs, Git global options, configured refspecs, and
#   malformed/absent push data.
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
# $1 is the remote Git passes to pre-push; the resolver uses it to tell a real
# push (stdin carries the authoritative ref lines) from a manual run.
cat > "$WORK/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
exec env DUDUDU_PRE_PUSH_REMOTE="${1:-}" bash tools/push-range.sh validate
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
# run_resolver <args...>: manual invocation (no pre-push marker, no push data).
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
# run_resolver_stdin <input> <args...>: exercise the official pre-push stream
# directly, with the marker a real hook sets.
run_resolver_stdin() {
  local input="$1"
  shift
  out="$(cd "$WORK" && printf '%s' "$input" | env DUDUDU_PRE_PUSH_REMOTE=origin bash tools/push-range.sh "$@" 2>&1)"
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
# Bootstrap: the first push to an empty remote is a new ref (remote SHA zero).
# The gate validates its full history; no bypass is needed.
# =============================================================================
commit_empty "chore(repo): bootstrap"
run_push origin main
expect_ok_like "first push to an empty remote validates the new ref" "refs=1"
expect_remote_has "first push reaches the remote" refs/heads/main
git -C "$WORK" fetch -q origin

# =============================================================================
# 1. First push of a new branch: remote SHA zero, full history validated.
# =============================================================================
git -C "$WORK" checkout -qb feat-a
commit_empty "feat(adapter): add the first probe"
run_push origin feat-a
expect_ok_like "new branch validates the carried commits" "PASS: 1 commit\(s\) validated"
expect_remote_has "first push of the branch reaches the remote" refs/heads/feat-a

# =============================================================================
# 2. Tracked push: the exact remote..local range is validated.
# =============================================================================
commit_empty "fix(sdk): tracked push probe"
run_push origin feat-a
expect_ok_like "tracked push validates against the remote SHA" "PASS: 1 commit\(s\) validated"
expect_remote_has "tracked push reaches the remote" refs/heads/feat-a

# =============================================================================
# 3. Empty push: Git reports no refs, explicit NO_NEW_COMMITS, still green.
# =============================================================================
run_push origin feat-a
expect_ok_like "empty push is explicit NO_NEW_COMMITS" "NO_NEW_COMMITS"

# =============================================================================
# 4. Invalid commit in the pushed range: rejected, remote unchanged.
# =============================================================================
before_tip="$(git --git-dir="$REMOTE" rev-parse refs/heads/feat-a)"
commit_empty "feat: missing scope must be rejected"
run_push origin feat-a
expect_fail_like "invalid commit in the pushed range is rejected" "expected '<type"
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
# 6. Multi-ref push: every ref's reported range is validated.
# =============================================================================
git -C "$WORK" checkout -qb b1 main
commit_empty "docs(repo): b1 content"
git -C "$WORK" checkout -qb b2 main
commit_empty "docs(repo): b2 content"
git -C "$WORK" checkout -q main
run_push origin b1 b2
expect_ok_like "multi-ref push validates both refs" "refs=2"
if [ "$(printf '%s\n' "$out" | grep -Ec 'PASS: [0-9]+ commit\(s\) validated')" -ge 2 ]; then
  report_pass "multi-ref push validates each range separately"
else
  report_fail "multi-ref push validates each range separately"
  printf '%s\n' "$out" | sed 's/^/     | /'
fi
expect_remote_has "multi-ref push reaches b1" refs/heads/b1
expect_remote_has "multi-ref push reaches b2" refs/heads/b2

# an invalid commit on ONE ref blocks the whole multi-ref push
git -C "$WORK" checkout -qb b3 main
commit_empty "feat: invalid commit on b3"
git -C "$WORK" checkout -q main
run_push origin b1 b3
expect_fail_like "one invalid ref blocks the multi-ref push" "expected '<type"
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
expect_ok_like "deletion via refspec publishes no commits" "deletion|no commits to validate"
expect_remote_lacks "refspec deletion removes the remote branch" refs/heads/b2
git -C "$WORK" branch -qD poison
git -C "$WORK" branch -qD b1

# =============================================================================
# 8. Brand-new remote: remote SHA zero, full history validated; an invalid
#    root published as a new ref must be rejected (never NO_NEW_COMMITS).
# =============================================================================
run_push remote2 main
expect_ok_like "new remote validates the full history of the new ref" "refs=1"
expect_remote_has "new-remote push reaches remote2" refs/heads/main "$REMOTE2"

# shellcheck disable=SC1083  # ^{tree} is git syntax, not shell
newbad="$(cd "$WORK" && git commit-tree "$(git rev-parse main^{tree})" -m "feat: invalid new-ref root commit")"
git -C "$WORK" update-ref refs/heads/newbad "$newbad"
run_push remote2 newbad
expect_fail_like "new-ref root message is validated" "expected '<type"
if printf '%s\n' "$out" | grep -Eiq "NO_NEW_COMMITS"; then
  report_fail "rejected new-ref root is not reported as NO_NEW_COMMITS"
else
  report_pass "rejected new-ref root is not reported as NO_NEW_COMMITS"
fi
expect_remote_lacks "rejected new-ref root publishes nothing" refs/heads/newbad "$REMOTE2"
git -C "$WORK" update-ref -d refs/heads/newbad

# =============================================================================
# 9. Wide push (--all) carrying an invalid root commit: must be rejected,
#    not reported as nothing-to-do (regression for the fail-open blocker).
# =============================================================================
git -C "$WORK" checkout -q -B widemain main
# shellcheck disable=SC1083  # ^{tree} is git syntax, not shell
root_invalid="$(cd "$WORK" && git commit-tree "$(git rev-parse main^{tree})" -m "feat: invalid orphan root commit")"
git -C "$WORK" update-ref refs/heads/orphan "$root_invalid"
run_push --all origin
expect_fail_like "wide push validates an invalid root commit by message" "expected '<type"
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
expect_ok_like "wide push accepts a valid root commit" "refs="
expect_remote_has "valid wide push publishes the orphan branch" refs/heads/orphan

# =============================================================================
# 11. Wide push (--all) with an invalid non-root commit on another branch.
# =============================================================================
git -C "$WORK" checkout -qb widebad main
commit_empty "feat: wide invalid commit"
git -C "$WORK" checkout -q widemain
run_push --all origin
expect_fail_like "wide push validates non-root commits from other branches" "expected '<type"
expect_remote_lacks "rejected wide push does not publish widebad" refs/heads/widebad

# =============================================================================
# 12. Manual mode: --range override, current-branch tracking, usage errors.
# =============================================================================
git -C "$WORK" checkout -q widemain
commit_empty "chore(repo): override probe"
run_resolver validate --range main widemain
expect_ok_like "explicit --range override validates the given range" "PASS: 1 commit\(s\) validated"
run_resolver validate
expect_ok_like "manual mode checks the current branch against its tracking ref" "PASS: 1 commit\(s\) validated"
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
# 15. Wildcard refspecs and negative exclusions are resolved by Git and
#     reported as individual ref lines.
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

# A refspec '*' crosses '/'. Only the slash-named branch is invalid, so a
# resolver that misses it goes green.
git -C "$WORK" checkout -qb slashok main
commit_empty "docs(repo): slash wildcard valid content"
git -C "$WORK" branch slash/bad "$(git -C "$WORK" rev-parse cfgpoison)"
git -C "$WORK" checkout -q main
run_push origin 'refs/heads/slash*:refs/heads/slash*'
expect_fail_like "wildcard '*' crosses '/' like Git refspecs" "expected '<type"
expect_remote_lacks "slash-crossing wildcard publishes no invalid ref" refs/heads/slash/bad
expect_remote_lacks "slash-crossing wildcard publishes no valid ref on rejection" refs/heads/slashok

# =============================================================================
# 16. Matching refspecs (P1): ':' and '+:' push every branch that exists on
#     both ends. Git reports those refs; a local invalid commit must be
#     rejected, and the remote must stay unchanged.
# =============================================================================
git -C "$WORK" checkout -qb matchpoison main
commit_empty "docs(repo): matching baseline"
git -C "$WORK" checkout -q main
run_push origin matchpoison
expect_ok_like "matching baseline branch is published" "PASS: 1 commit\(s\) validated"
git -C "$WORK" fetch -q origin
git -C "$WORK" checkout -q matchpoison
commit_empty "feat: invalid commit behind a matching refspec"
git -C "$WORK" checkout -q main
match_before="$(git --git-dir="$REMOTE" rev-parse refs/heads/matchpoison)"
run_push origin :
expect_fail_like "matching refspec ':' validates the matching branch" "expected '<type"
if [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/matchpoison)" = "$match_before" ]; then
  report_pass "rejected ':' push leaves the remote tip unchanged"
else
  report_fail "rejected ':' push leaves the remote tip unchanged"
fi
run_push origin +:
expect_fail_like "force matching refspec '+:' validates the matching branch" "expected '<type"
if [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/matchpoison)" = "$match_before" ]; then
  report_pass "rejected '+:' push leaves the remote tip unchanged"
else
  report_fail "rejected '+:' push leaves the remote tip unchanged"
fi
# With the invalid commit removed, the remaining matching updates are valid.
git -C "$WORK" checkout -q matchpoison
git -C "$WORK" reset -q --hard origin/matchpoison
git -C "$WORK" checkout -q main
run_push origin :
expect_ok_like "matching refspec publishes only valid matching branches" "PASS: 1 commit\(s\) validated"

# =============================================================================
# 17. Mirror pushes (P1): Git reports refs/remotes/* and every other ref
#     namespace. A commit reachable only through a remote-tracking ref is
#     published by --mirror and must be validated.
# =============================================================================
# Remove every unrelated invalid local branch first, so each rejection below
# can only be caused by the mirror-specific ref under test.
invalid_ref_sha="$(git -C "$WORK" rev-parse cfgpoison)"
git -C "$WORK" branch -qD optpoison cfgpoison widebad wildbad slash/bad
# shellcheck disable=SC1083  # ^{tree} is git syntax, not shell
mirror_invalid="$(cd "$WORK" && git commit-tree "$(git rev-parse main^{tree})" -m "feat: invalid mirror-only commit")"
git -C "$WORK" update-ref refs/remotes/origin/mirrorpoison "$mirror_invalid"
run_push --mirror origin
expect_fail_like "mirror validates remote-tracking refs it publishes" "expected '<type"
expect_remote_lacks "rejected mirror publishes no remote-tracking ref" refs/remotes/origin/mirrorpoison
git -C "$WORK" update-ref -d refs/remotes/origin/mirrorpoison

git -C "$WORK" update-ref refs/deploy/invalid "$invalid_ref_sha"
run_push --mirror origin
expect_fail_like "mirror validates refs outside branches and tags" "expected '<type"
expect_remote_lacks "rejected mirror push publishes no deploy ref" refs/deploy/invalid
git -C "$WORK" config remote.origin.mirror true
run_push origin
expect_fail_like "remote.<name>.mirror bare push validates every reported ref" "expected '<type"
expect_remote_lacks "rejected configured mirror publishes no deploy ref" refs/deploy/invalid
git -C "$WORK" config --unset remote.origin.mirror
run_git_push_from "$WORK" -c remote.origin.mirror=true push origin
expect_fail_like "command-line -c remote.<name>.mirror is honored" "expected '<type"
expect_remote_lacks "rejected -c mirror publishes no deploy ref" refs/deploy/invalid

# A valid mirror is genuinely checked, not rejected as a class.
git -C "$WORK" update-ref -d refs/deploy/invalid
run_push --mirror origin
expect_ok_like "valid mirror push is validated and accepted" "refs="
expect_remote_has "valid mirror publishes a branch namespace ref" refs/heads/slashok
expect_remote_has "valid mirror publishes a remote-tracking ref" refs/remotes/origin/main

# =============================================================================
# 18. Push options do not disturb Git's ref data.
# =============================================================================
git -C "$WORK" checkout -qb rsok main
commit_empty "docs(repo): recurse-submodules option value"
git -C "$WORK" checkout -q main
run_git_push_from "$WORK" push --recurse-submodules no origin rsok
expect_ok_like "space-separated option values do not hide the pushed ref" "refs=1"
expect_remote_has "option-bearing push publishes the real target" refs/heads/rsok

# =============================================================================
# 19. Path-aware build trigger (P2): benchmark sources count, docs do not;
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
# 20. Direct stdin contract: the resolver trusts exactly the reported SHAs,
#     fails closed on malformed data, and never treats unchecked refs as
#     NO_NEW_COMMITS.
# =============================================================================
main_sha="$(git -C "$WORK" rev-parse main)"
zero_sha="0000000000000000000000000000000000000000"

run_resolver_stdin '' validate
expect_ok_like "empty pre-push stream is NO_NEW_COMMITS" "NO_NEW_COMMITS"

run_resolver_stdin "refs/heads/main not-a-sha refs/heads/main $zero_sha"$'\n' validate
expect_fail_like "malformed pre-push line is a hard failure" "malformed pre-push line"
if printf '%s\n' "$out" | grep -Eiq "NO_NEW_COMMITS"; then
  report_fail "malformed push data is not reported as NO_NEW_COMMITS"
else
  report_pass "malformed push data is not reported as NO_NEW_COMMITS"
fi

run_resolver_stdin "refs/heads/ghost 1111111111111111111111111111111111111111 refs/heads/ghost $zero_sha"$'\n' validate
expect_fail_like "unresolvable local object is a hard failure" "cannot be resolved to a commit"

git -C "$WORK" checkout -qb stdinok main
commit_empty "docs(repo): direct stdin valid commit"
stdinok_sha="$(git -C "$WORK" rev-parse stdinok)"
git -C "$WORK" checkout -qb stdinbad main
commit_empty "feat: direct stdin invalid commit"
stdinbad_sha="$(git -C "$WORK" rev-parse stdinbad)"
git -C "$WORK" checkout -q main

run_resolver_stdin "refs/heads/stdinok $stdinok_sha refs/heads/stdinok $main_sha"$'\n' validate
expect_ok_like "reported range is validated from the official SHAs" "PASS: 1 commit\(s\) validated"
run_resolver_stdin "refs/heads/stdinbad $stdinbad_sha refs/heads/stdinbad $main_sha"$'\n' validate
expect_fail_like "reported invalid commit is rejected" "expected '<type"
run_resolver_stdin "refs/heads/gone $zero_sha refs/heads/gone $main_sha"$'\n' validate
expect_ok_like "reported deletion publishes no commits" "deletion|no commits to validate"
run_resolver_stdin "refs/heads/stdinok $stdinok_sha refs/heads/stdinok 2222222222222222222222222222222222222222"$'\n' validate
expect_ok_like "absent remote object falls back to full-history validation" "absent locally"

# lefthook leaves {1} literal in a manual run: stdin must be ignored, so a
# manual gate cannot be poisoned by whatever happens to be on stdin.
out="$(cd "$WORK" && printf 'garbage\n' | env DUDUDU_PRE_PUSH_REMOTE='{1}' bash tools/push-range.sh validate --range main stdinok 2>&1)"
rc=$?
expect_ok_like "literal {1} selects manual mode and ignores stdin" "PASS: 1 commit\(s\) validated"

git -C "$WORK" branch -qD stdinok stdinbad

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
