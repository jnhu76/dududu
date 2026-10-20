#!/usr/bin/env bash
# Independent structural validation of a dududu parquet I/O trace (JSONL).
#
#   bash benchmarks/parquet/validate-trace.sh <trace.jsonl> [<trace2.jsonl>]
#
# This is deliberately NOT the C++ parser (experiments/parquet/src/io_trace.cpp
# parse_trace): it re-derives the format contract with jq so the two layers
# share no code and a bug in one cannot hide the other. Checks:
#   * the file ends with a newline and every physical line is exactly one
#     JSON object (two values on one line is not JSON Lines);
#   * the header has exactly the contracted keys, the contracted
#     type/version, a 64-hex-digit dataset digest and a positive file size;
#   * request records have exactly {i,offset,requested,returned,ok}, dense
#     zero-based indices, integer fields, requested>=1,
#     returned<=requested, and offset+returned inside file_size;
#   * with a second trace: identical file_size, dataset identity and request
#     lists, record for record (the cross-arm identity the protocol needs).
set -euo pipefail

fail() {
    echo "validate-trace: FAIL: $*" >&2
    exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: validate-trace.sh <trace.jsonl> [<trace2.jsonl>]"

read -r -d '' semantic <<'JQ' || true
def hex64: test("^[0-9a-f]{64}$");
def intfield: type == "number" and floor == .;
.[0].file_size as $fs
| (length >= 2)
and ((.[0] | keys) == (["arm","dataset_path","dataset_sha","file_size","type","version","workload"] | sort))
and (.[0].type == "dududu-parquet-io-trace")
and (.[0].version == 1)
and (.[0].dataset_sha | type == "string" and hex64)
and (.[0].dataset_path | type == "string" and length > 0)
and (.[0].workload | IN("t1_meta", "t2_projection", "t3_full"))
and (.[0].arm | type == "string" and length > 0)
and (.[0].file_size | type == "number" and . >= 1)
and ([ .[1:] | to_entries[]
      | (.key == .value.i)
        and ((.value | keys) == (["i","offset","ok","requested","returned"] | sort))
        and (.value.offset | intfield) and (.value.offset >= 0) and (.value.offset <= $fs)
        and (.value.requested | intfield) and (.value.requested >= 1)
        and (.value.returned | intfield) and (.value.returned >= 0)
        and (.value.returned <= .value.requested)
        and (.value.offset + .value.returned <= $fs)
        and (.value.ok | type == "boolean")
     ] | all)
JQ

validate_one() { # <trace.jsonl>
    local file="$1"
    [[ -f "$file" ]] || fail "no such trace: $file"
    [[ -s "$file" ]] || fail "empty trace: $file"
    [[ -z "$(tail -c 1 "$file")" ]] || fail "$file: missing trailing newline"
    local lineno=0 line
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        [[ -n "$line" ]] || fail "$file:$lineno: blank line"
        printf '%s' "$line" | jq -s -e 'length == 1' >/dev/null 2>&1 \
            || fail "$file:$lineno: not exactly one JSON object on the line"
    done < "$file"

    # Semantic contract over the slurped record array. -e makes a false
    # verdict (and any parse error) nonzero.
    jq -s -e "$semantic" "$file" >/dev/null \
        || fail "$file: semantic contract violated (keys, indices, bounds or header fields)"
}

validate_one "$1"
if [[ $# -eq 2 ]]; then
    validate_one "$2"
    jq -n -e \
        --slurpfile a "$1" --slurpfile b "$2" \
        '($a[0].file_size == $b[0].file_size)
         and ($a[0].dataset_sha == $b[0].dataset_sha)
         and ($a[1:] == $b[1:])' \
        >/dev/null || fail "request lists differ between $1 and $2"
    echo "validate-trace: PASS ($1, $2: $(wc -l < "$1") lines each, identical request lists)"
else
    echo "validate-trace: PASS ($1: $(wc -l < "$1") lines)"
fi
