#!/usr/bin/env bash
# Negative-first self-test for benchmarks/parquet/validate-trace.sh.
#
# A validator that cannot be seen rejecting bad input is not a gate. Every
# case below constructs a concrete malformed trace (or a pair) and asserts
# the verdict. The truncated-header case is the exact artifact shape the
# serializer bug produced: a header line without its closing brace.
set -u

here=$(cd "$(dirname "$0")" && pwd)
validator="$here/../validate-trace.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
fail_now() {
    echo "FAIL: $*" >&2
    fails=$((fails + 1))
}

expect_pass() { # <label> <args...>
    cases=$((cases + 1))
    if ! bash "$validator" "${@:2}" >/dev/null 2>&1; then
        fail_now "expected PASS, got reject: $1"
    fi
}

expect_reject() { # <label> <args...>
    cases=$((cases + 1))
    if bash "$validator" "${@:2}" >/dev/null 2>&1; then
        fail_now "expected REJECT, got pass: $1"
    fi
}

sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
header_close=',"arm":"p1-native","file_size":1000}'
header_open='{"type":"dududu-parquet-io-trace","version":1,"dataset_sha":"'$sha'"'
header_open+=',"dataset_path":"/tmp/x.parquet","workload":"t3_full"'
req0='{"i":0,"offset":0,"requested":64,"returned":64,"ok":true}'
req1='{"i":1,"offset":100,"requested":900,"returned":800,"ok":true}'

w() { # <file> <lines...>
    local f="$tmp/$1"
    shift
    : > "$f"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$f"
    done
}

# --- admitted shapes --------------------------------------------------------
w good.jsonl "$header_open$header_close" "$req0" "$req1"
expect_pass "well-formed trace" "$tmp/good.jsonl"

w good2.jsonl "$header_open$header_close" "$req0" "$req1"
expect_pass "cross-arm pair, identical requests" "$tmp/good.jsonl" "$tmp/good2.jsonl"

# --- rejected shapes --------------------------------------------------------
# The exact pre-fix artifact: header lost its closing brace.
w bad-header.jsonl "${header_open}${header_close%?}" "$req0"
expect_reject "truncated header (missing brace)" "$tmp/bad-header.jsonl"

# Two JSON objects on one physical line is not JSON Lines.
w two-on-line.jsonl "$header_open$header_close$req0"
expect_reject "two objects on one line" "$tmp/two-on-line.jsonl"

w blank-line.jsonl "$header_open$header_close" "" "$req0"
expect_reject "blank record" "$tmp/blank-line.jsonl"

w garbage.jsonl "$header_open$header_close" "not json at all"
expect_reject "non-JSON record" "$tmp/garbage.jsonl"

w no-final-newline.jsonl "$header_open$header_close" "$req0"
printf '%s' '{"i":1,"offset":10,"requested":9,"returned":9,"ok":true}' >> "$tmp/no-final-newline.jsonl"
expect_reject "unterminated last line" "$tmp/no-final-newline.jsonl"

w bad-digest.jsonl "${header_open/$sha/abc}$header_close" "$req0"
expect_reject "dataset_sha not a 64-hex digest" "$tmp/bad-digest.jsonl"

w bad-workload.jsonl "$(printf '%s' "$header_open" | sed 's/t3_full/typo_scan/')$header_close" "$req0"
expect_reject "unknown workload" "$tmp/bad-workload.jsonl"

w extra-header-key.jsonl "${header_open}${header_close%?}},\"extra\":1}" "$req0"
expect_reject "unknown header key" "$tmp/extra-header-key.jsonl"

w bad-index.jsonl "$header_open$header_close" \
    '{"i":1,"offset":0,"requested":64,"returned":64,"ok":true}'
expect_reject "non-dense index" "$tmp/bad-index.jsonl"

w short-count.jsonl "$header_open$header_close" \
    '{"i":0,"offset":0,"requested":8,"returned":9,"ok":true}'
expect_reject "returned > requested" "$tmp/short-count.jsonl"

w out-of-file.jsonl "$header_open$header_close" \
    '{"i":0,"offset":990,"requested":64,"returned":64,"ok":true}'
expect_reject "offset+returned beyond file_size" "$tmp/out-of-file.jsonl"

w zero-request.jsonl "$header_open$header_close" \
    '{"i":0,"offset":0,"requested":0,"returned":0,"ok":true}'
expect_reject "empty request" "$tmp/zero-request.jsonl"

w missing-ok.jsonl "$header_open$header_close" \
    '{"i":0,"offset":0,"requested":64,"returned":64}'
expect_reject "missing ok field" "$tmp/missing-ok.jsonl"

w extra-req-key.jsonl "$header_open$header_close" \
    '{"i":0,"offset":0,"requested":64,"returned":64,"ok":true,"extra":1}'
expect_reject "unknown request key" "$tmp/extra-req-key.jsonl"

# Cross-arm mode: a differing request list must fail the pair.
w diverged.jsonl "$header_open$header_close" "$req0" \
    '{"i":1,"offset":100,"requested":900,"returned":799,"ok":true}'
expect_reject "cross-arm pair with diverged requests" \
    "$tmp/good.jsonl" "$tmp/diverged.jsonl"

expect_reject "missing file" "$tmp/does-not-exist.jsonl"

if [[ $fails -ne 0 ]]; then
    echo "validate-trace-test: $fails failure(s) over $cases cases" >&2
    exit 1
fi
echo "validate-trace-test: PASS ($cases cases, negative-first)"
