# fio R0 native storage baseline (E5)

Preparation for the #578 R0 native storage floor on the E5 host. This directory
freezes **what will be measured** — job files, dataset identity, cache policy and
filesystem identity — so the formal runs need no ad-hoc decisions. **No
measurement exists yet**: the formal runs and the A/A noise assessment belong to
the serial measurement lane; nothing in this directory is a performance result.

## Tool identity

| Field | Value | Established |
|---|---|---|
| `fio` | 3.40 (`fio-3.40-3.fc44`, x86_64, from the Fedora 44 official repo) | `fio --version`, `rpm -qi fio`, 2026-10-29 |
| Engines load-tested (tooling smoke on a throwaway tmpfs file) | `psync`, `libaio`, `io_uring` all completed real I/O on kernel 7.2.11 | 2026-10-29, outputs discarded — smoke proves the tools run, it is not a measurement |

`perf_event_paranoid=2` on this host limits perf to user-space; it does not
affect fio.

## Host identity (frozen at prep time)

- E5: Intel Xeon E5-2666 v3 @ 2.90 GHz, 1 socket / 10 cores / SMT2 = 20 CPUs,
  single NUMA node, 62 GB RAM, zram swap.
- Fedora 44, kernel 7.2.11-200.fc44.x86_64.
- Dataset filesystem: **btrfs on /dev/sda3 (`/home`), options
  `rw,relatime,seclabel,compress=zstd:1,ssd,discard=async,space_cache=v2`**.
  Re-capture with `findmnt -T <dataset dir>` and record it in every run
  manifest.
- CPU governor is `schedutil` (not `performance`); it was **not** changed.
  Record `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` per run.
- `/tmp` is tmpfs: never host the fio dataset there; a tmpfs number is a memory
  number, not a storage number.

## Dataset identity

Three 8 GiB files under the ignored `build/fio-r0-data/`, filled with
`/dev/urandom` bytes:

```bash
mkdir -p build/fio-r0-data
for f in r0-rand-8g.bin r0-seq-1m.bin r0-randrw-8g.bin; do
  dd if=/dev/urandom of=build/fio-r0-data/$f bs=4M count=2048 status=none
done
sync
sha256sum build/fio-r0-data/*.bin | tee -a <run-manifest>   # per-run identity
```

Random content is deliberate, not waste: with `compress=zstd:1`, compressible
content (zeros, a fixed pattern) changes the storage's real work and therefore
the measurement. Incompressible content keeps the btrfs compression path out of
the result. A fresh `/dev/urandom` fill is byte-different each time — the frozen
identity is **size + generation method + per-run SHA-256**, recorded in the run
manifest, not a byte-exact golden file.

`r0-randrw-4k.fio` writes to its file: after any `randrw` run the hash no longer
matches the prep record. Re-run the prep (or re-hash and record the new value)
before reusing that dataset for a read job.

## Job files and their identity dimensions

| Section (file) | ioengine | iodepth | bs | rw | cache | dataset |
|---|---|---|---|---|---|---|
| `r0-sync-4k-direct` (r0-read-4k.fio) | psync | 1 | 4k | randread | direct=1 | r0-rand-8g.bin |
| `r0-sync-4k-buffered` (r0-read-4k.fio) | psync | 1 | 4k | randread | **buffered** | r0-rand-8g.bin |
| `r0-libaio-4k-qd32-direct` (r0-read-4k.fio) | libaio | 32 | 4k | randread | direct=1 | r0-rand-8g.bin |
| `r0-io_uring-4k-qd32-direct` (r0-read-4k.fio) | io_uring | 32 | 4k | randread | direct=1 | r0-rand-8g.bin |
| `r0-seqread-1m-direct` (r0-seqread-1m.fio) | psync | 1 | 1M | read (seq) | direct=1 | r0-seq-1m.bin |
| `r0-randrw-4k-r75-direct` (r0-randrw-4k.fio) | psync | 1 | 4k | randrw 75/25 | direct=1 | r0-randrw-8g.bin |

All sections: one process (`numjobs=1`), `runtime=30`, `ramp_time=5`,
`time_based`, `group_reporting`, fixed `randseed=20261029` where the pattern is
random. Every section is a distinct load: ioengine, iodepth, block size, access
pattern, read/write mix and cache policy are identity dimensions. **A number
from one section is never comparable to, or substitutable for, a number from
another, and no aggregate across sections exists.** Report engine identity next
to every number.

## Cache policy

- `direct=1` sections bypass the page cache; no privileged preparation needed.
- `r0-sync-4k-buffered` reads through the page cache and is **warm-cache only**
  until a cold protocol exists. A cold-cache protocol needs
  `drop_caches` (root); the sudo granted for prep is scoped to installing
  measurement tools, so a cold-buffered run requires an explicit owner decision
  before the measurement lane uses it.

## Run form (for the serial measurement lane)

One section per invocation, machine-readable output plus the text copy:

```bash
fio --section=r0-sync-4k-direct \
    --directory=$PWD/build/fio-r0-data \
    --output=build/fio-r0-data/<run-id>-r0-sync-4k-direct.json \
    --output-format=json \
    benchmarks/fio-r0/r0-read-4k.fio
```

Each run manifest records: fio version, job section, `findmnt -T` of the dataset
directory, dataset SHA-256, governor, load average / competing activity check,
and start/end times. A/A pairs repeat the identical section invocation.

All files validate: `fio --parse-only --section=<name> <file>` (checked
2026-10-29, all six sections parse clean).
