#!/usr/bin/env python3
"""Classify the pread(2) request stream DuckDB v1.5.6 issues while scanning a
Parquet file, and quantify which consecutive requests form legal coalescing
windows.

Inputs
  --trace    strace -f -y -e trace=pread64 output of a DuckDB run
  --chunks   TSV from parquet_metadata(): row_group_id, column_id,
             dictionary_page_offset, data_page_offset, total_compressed_size
             (all 16 columns; the analyzer selects the projected ones)
  --dataset  path of the Parquet file the trace was taken against

Outputs (written next to the trace-derived --label)
  <label>-requests.csv   one row per pread on the dataset, classified
  <label>-geometry.json  every computed statistic

The classifier is total: any request it cannot attribute is an error, not a
bucket. Regenerate the traces with the commands in results/trace-index.md.
"""

import argparse
import collections
import csv
import json
import re
import sys
from pathlib import Path

PROJECTED_COLUMNS = {"5", "6", "7"}  # l_extendedprice, l_discount, l_tax

LINE_RE = re.compile(r"^(\d+)\s+(.*)$")
COMPLETE_RE = re.compile(
    r'^pread64\((\d+)<([^>]*)>(?:, "(?:[^"\\]|\\.)*")?(?:\.\.\.)?, (\d+), (\d+)\)\s*=\s*(\d+)'
)
UNFINISHED_RE = re.compile(r"^pread64\((\d+)<([^>]*)>\s*<unfinished \.\.\.>$")
RESUMED_RE = re.compile(
    r'^<\.\.\. pread64 resumed>(?:, "(?:[^"\\]|\\.)*")?(?:\.\.\.)?, (\d+), (\d+)\)\s*=\s*(\d+)'
)


def parse_trace(path):
    """Return every pread64 as (line_no, tid, fd, path, length, offset, ret)
    in completion order. strace splits a syscall that was interleaved with
    another thread into an `unfinished` start line and a `resumed` line; the
    start carries fd+path, the resumed line carries length+offset+return.
    Pairs are matched FIFO per tid (a thread has at most one outstanding
    syscall)."""
    pending, requests = {}, []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line_no, line in enumerate(f, 1):
            m = LINE_RE.match(line.rstrip("\n"))
            if not m:
                continue
            tid, body = m.group(1), m.group(2)
            u = UNFINISHED_RE.match(body)
            if u:
                pending[tid] = (u.group(1), u.group(2))
                continue
            r = RESUMED_RE.match(body)
            if r:
                fd, p = pending.pop(tid, (None, None))
                if fd is None:
                    sys.exit(f"{path}:{line_no}: resumed pread64 without a start line")
                requests.append(
                    (line_no, tid, fd, p, int(r.group(1)), int(r.group(2)), int(r.group(3)))
                )
                continue
            c = COMPLETE_RE.match(body)
            if c:
                requests.append(
                    (line_no, tid, c.group(1), c.group(2), int(c.group(3)), int(c.group(4)), int(c.group(5)))
                )
    return requests


def load_chunks(path):
    chunks = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            rg, col, dict_off, data_off, size = line.rstrip("\n").split("|")
            dict_off = None if dict_off == "NULL" else int(dict_off)
            start = min(x for x in (dict_off, int(data_off)) if x is not None)
            chunks[(int(rg), col)] = {
                "dict_off": dict_off,
                "data_off": int(data_off),
                "start": start,
                "end": start + int(size),
            }
    return chunks


def row_group_spans(chunks):
    """Projected-chunk union span per row group, plus the contiguity check that
    makes the span a single legal file range."""
    spans = {}
    for (rg, col), c in chunks.items():
        spans.setdefault(rg, {})[col] = c
    out = {}
    for rg, cols in spans.items():
        ordered = sorted(cols.items())
        start = ordered[0][1]["start"]
        end = ordered[-1][1]["end"]
        contiguous = all(
            ordered[i][1]["end"] == ordered[i + 1][1]["start"] for i in range(len(ordered) - 1)
        )
        out[rg] = {"start": start, "end": end, "bytes": end - start, "contiguous": contiguous}
    return out


def classify(requests, chunks, file_size):
    """Attribute every dataset pread to the metadata-resolution step that
    triggered it. Every request must land in exactly one class."""
    by_span = collections.defaultdict(list)
    for (rg, col), c in chunks.items():
        by_span[(c["start"], c["end"])].append((rg, col, c))

    rows = []
    unclassified = []
    for line_no, tid, fd, path, length, offset, ret in requests:
        row = {
            "line": line_no,
            "tid": tid,
            "fd": fd,
            "offset": offset,
            "length": length,
            "ret": ret,
            "class": None,
            "row_group": None,
            "column": None,
        }
        if offset + ret == file_size and length == 8:
            row["class"] = "footer_tail_probe"
        elif offset + ret == file_size - 8:
            row["class"] = "footer"
        else:
            hit = [v for k, v in by_span.items() if k[0] <= offset and offset + ret <= k[1]]
            if len(hit) == 1:
                rg, col, c = hit[0][0]
                row["row_group"], row["column"] = rg, col
                cs, ce, dp = c["start"], c["end"], c["data_off"]
                if offset == cs and length == 256:
                    row["class"] = "page_header_window"
                elif offset == dp and length == 256:
                    row["class"] = "data_page_header_window"
                elif offset + ret == ce:
                    row["class"] = "page_body"
                elif offset == cs + 256 and length == dp - cs:
                    row["class"] = "cache_interleave_piece"
                elif offset + ret == dp:
                    row["class"] = "dict_page_data"
            if row["class"] is None:
                hit_any = [v for k, v in by_span.items() if k[0] <= offset < k[1]]
                if hit_any:
                    rg, col, c = hit_any[0][0]
                    row["row_group"], row["column"] = rg, col
                    row["class"] = "UNCLASSIFIED_IN_CHUNK"
                else:
                    row["class"] = "UNCLASSIFIED_OUTSIDE_CHUNK"
        if row["class"].startswith("UNCLASSIFIED"):
            unclassified.append(row)
        rows.append(row)
    return rows, unclassified


def geometry_stats(rows, chunks, rg_spans, label):
    per_class = collections.Counter(r["class"] for r in rows)
    per_class_bytes = collections.defaultdict(int)
    for r in rows:
        per_class_bytes[r["class"]] += r["ret"]

    total_calls = len(rows)
    total_bytes = sum(r["ret"] for r in rows)
    short_reads = [r for r in rows if r["ret"] != r["length"]]
    micro = [r for r in rows if r["length"] <= 4096]

    # per-fd order: contiguity / overlap / gaps in issue order
    per_fd = collections.defaultdict(list)
    for r in rows:
        per_fd[r["fd"]].append(r)
    fd_summary = {}
    for fd, seq in per_fd.items():
        contig = backward = 0
        gaps = []
        for a, b in zip(seq, seq[1:]):
            a_end = a["offset"] + a["ret"]
            if b["offset"] == a_end:
                contig += 1
            elif b["offset"] < a_end:
                backward += 1
            else:
                gaps.append(b["offset"] - a_end)
        fd_summary[fd] = {
            "requests": len(seq),
            "exact_contiguous_pairs": contig,
            "backward_overlap_pairs": backward,
            "gap_count": len(gaps),
            "gap_min": min(gaps) if gaps else None,
            "gap_max": max(gaps) if gaps else None,
            "bytes": sum(r["ret"] for r in seq),
        }

    extents = collections.Counter((r["offset"], r["length"]) for r in rows)
    repeated = {f"{o}+{l}": n for (o, l), n in extents.items() if n > 1}

    distinct_fds = len(fd_summary)
    scan_fds = {fd: s for fd, s in fd_summary.items() if s["requests"] > 2}

    # legal merged-span projection: one read per row-group projected-chunk span
    span_bytes = {rg: s["bytes"] for rg, s in rg_spans.items()}
    all_contiguous = all(s["contiguous"] for s in rg_spans.values())
    merged_total = sum(span_bytes.values())

    return {
        "label": label,
        "total_preads": total_calls,
        "total_bytes_returned": total_bytes,
        "short_reads": len(short_reads),
        "calls_le_4kib": len(micro),
        "bytes_le_4kib": sum(r["ret"] for r in micro),
        "distinct_fds": distinct_fds,
        "scan_fds": len(scan_fds),
        "requests_per_class": dict(sorted(per_class.items())),
        "bytes_per_class": dict(sorted(per_class_bytes.items())),
        "repeated_extents": repeated,
        "per_fd": fd_summary,
        "row_group_span_contiguous_all": all_contiguous,
        "row_group_count": len(rg_spans),
        "merged_span_bytes_total": merged_total,
        "legal_merged_preads_default_footer": 1 + len(rg_spans),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--chunks", required=True)
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--projected", default=",".join(sorted(PROJECTED_COLUMNS)),
                    help="comma-separated column_ids of the scan projection")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    file_size = Path(args.dataset).stat().st_size
    all_chunks = load_chunks(args.chunks)
    projected = set(args.projected.split(","))
    chunks = {k: v for k, v in all_chunks.items() if k[1] in projected}
    rg_spans = row_group_spans(chunks)

    requests = parse_trace(args.trace)
    on_dataset = [r for r in requests if r[3] and r[3].endswith(Path(args.dataset).name)]
    rows, unclassified = classify(on_dataset, chunks, file_size)

    if unclassified:
        for r in unclassified[:10]:
            print("UNCLASSIFIED:", r, file=sys.stderr)
        sys.exit(f"{len(unclassified)} requests could not be attributed")

    stats = geometry_stats(rows, chunks, rg_spans, args.label)
    stats["trace"] = str(args.trace)
    stats["dataset"] = args.dataset
    stats["dataset_size"] = file_size
    stats["projected_columns"] = sorted(projected)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / f"{args.label}-requests.csv"
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    json_path = out_dir / f"{args.label}-geometry.json"
    json_path.write_text(json.dumps(stats, indent=2) + "\n", encoding="utf-8")

    print(f"{args.label}: {stats['total_preads']} preads, {stats['total_bytes_returned']} B, "
          f"{stats['calls_le_4kib']} <=4KiB ({stats['bytes_le_4kib']} B), "
          f"{stats['distinct_fds']} fds, classes: {stats['requests_per_class']}")
    print(f"wrote {csv_path} and {json_path}")


if __name__ == "__main__":
    main()
