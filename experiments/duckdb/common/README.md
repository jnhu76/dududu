# common — shared arm scaffolding

Status: **R0 documented rules only. No source code.**

This directory is the agreed home for code that more than one arm needs, so that
an arm README never has to say "same as the other one" without a file to point
at. It exists now as a decision, not as an implementation.

## What may live here

Only code that is provably arm-independent:

- a host-side registration shim that installs a `FileSystem` into a DuckDB
  instance in the same way for every arm that needs one,
- shared benchmark invocation helpers that read configuration from the
  environment rather than hardcoding an arm name,
- shared result-schema definitions, so the five arms emit comparable records.

## What must not live here

- Anything that decides **which** arm is running. Arm identity comes from the
  experiment directory, never from a shared switch: a shared `enable_sluice`
  flag is how arms stop being distinguishable.
- Timing code. `std::chrono` loops written here would compete with DuckDB's own
  benchmark harness, which already owns warmup, repetition counts, timeouts and
  result verification (`docs/experiment-matrix.md`, rule 6).
- Fallbacks. If an arm cannot run because the host environment lacks a
  capability, the arm reports `NOT_SUPPORTED` / `BLOCKED` for itself. A shared
  silent path to native I/O would turn "Sluice was slower" into "Sluice was
  never called", and that failure mode is invisible in a timing number.

## Why the directory is empty in R0

R0 is foundation only. Every arm is at status R1 or R2, and none of them has
been admitted, so there is nothing yet that is genuinely shared. Creating files
here now would mean guessing at an interface before the first arm exists, which
is the same mistake as writing an arm README that promises code.

The rules above are what an arm must satisfy before it may add a file here.
