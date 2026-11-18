# rv32-uarch-perf

Micro-architecture and performance work on my RV32I 5-stage pipelined core
(from [rv32-emu-verif](../rv32-emu-verif)):

- **RTL:** a direct-mapped instruction cache in front of a slow instruction
  memory, a branch predictor (2-bit counter BHT + tagged BTB), and hardware
  performance counters that add up to an exact CPI stack. Each feature has a
  parameter that turns it off, giving back the original core.
- **Correctness:** a Verilator C++ testbench checks every retired instruction
  against a C reference model, plus SVA properties and cover points, on four
  configs (cache on/off x predictor on/off).
- **C++ performance model** (C++17) of the same pipeline, cache and
  predictor, compared with the RTL counters per benchmark.
- **Study:** IPC vs I-cache size, with and without branch prediction, on seven
  hand-written RV32I benchmarks. The summary table is written by a Perl script.

It found two real bugs in the core, one of them latent in the original
design. See [BUGS.md](BUGS.md). Interview-style explanations are in
[INTERVIEW_NOTES.md](INTERVIEW_NOTES.md).

## Architecture

```
                 +-------------- redirect_pc (mispredict, from EX) ----------------+
                 |                                                                 |
                 v                                                                 |
   +----------+  pc   +-------------------------+                                  |
   |    PC    |------>| icache.v                |  instr, ready                    |
   | register |       |  direct-mapped, LINES x |-----------+                      |
   +----------+       |  LINE_WORDS, valid+tag  |           |                      |
      ^     |         |  miss: refill whole line|           v                      |
      |     |         |  from imem after        |      +---------+   +----+   +----+----+   +-----+   +----+
      |     |         |  MISS_LAT cycles        |      |  IF/ID  |-->| ID |-->|   EX    |-->| MEM |-->| WB |--> retire trace
      |     |         +-------------------------+      | +pred,  |   |    |   | resolve |   |     |   |    |    (rvfi_*) -> C model
      |     |  pc     +-------------------------+      | +cause  |   +----+   | branch, |   +-----+   +----+
      |     +-------->| bpred.v                 |      +---------+     |      | compare |                |
      |               |  BTB (16, tagged)       |                 load-use  | next PC |                |
      +---------------|  BHT (64 x 2-bit)       |<------------- update -----+---------+                |
        predicted     +-------------------------+                 (EX)                                  |
        next pc                                                                                         v
                                                       perf counters: cycles, instret, I$ access/miss,
                                                       branches, jumps, mispredicts, bubbles by cause
```

- **Fetch.** IF looks up the I-cache and the predictor with the same PC. On a
  hit the instruction goes to IF/ID and the PC moves to the predicted next PC
  (BTB target if predicted taken, else pc+4). On a miss the PC holds, IF/ID
  gets a bubble, and the cache refills the line: one miss costs
  `1 + MISS_LAT` cycles. The cache is blocking and a refill is never
  cancelled.
- **Resolve.** EX computes the real next PC and compares it with the one IF
  guessed. If they differ, IF/ID and ID/EX are flushed (2-cycle penalty) and
  the PC is redirected. The BHT and BTB are updated in EX.
- **Counters.** Every bubble carries the reason it was made (cold start,
  I-cache, load-use, branch). When it reaches WB its counter goes up, so
  `cycles = instret + bubbles` exactly; the testbench checks this every run.
- **Off switches.** `ICACHE_EN=0` reads the instruction memory directly
  (ideal 1-cycle fetch, the original core). `BP_EN=0` predicts not taken
  (the original core, apart from the fix for BUGS.md bug 1).

| File | What |
|---|---|
| `rtl/icache.v` | I-cache + backing instruction memory (`EN`, `LINES`, `LINE_WORDS`, `MISS_LAT`) |
| `rtl/bpred.v` | BHT + BTB (`EN`, `BHT_ENTRIES`, `BTB_ENTRIES`) |
| `rtl/riscv_core.v` | the 5-stage core, now with prediction, redirect on mispredict, counters |
| `rtl/alu.v`, `regfile.v`, `imm_gen.v`, `control_unit.v` | unchanged from the original |
| `sva/core_sva.sv` | assertions and cover points, bound to the core |
| `tb/tb_main.cpp` | Verilator C++ testbench: load, run, compare with the C model, read counters |
| `model/rv32i_iss.c` | C reference model (from rv32-emu-verif, unchanged) |
| `model/perf_model.cpp` | C++ performance model |
| `bench/*.asm` | the seven benchmarks |
| `tests/directed/*.asm` | directed tests (six from rv32-emu-verif + `link_forward`) |
| `tools/assemble.py`, `tools/rvgen.py` | assembler and random program generator (rvgen gained `--loops`) |
| `scripts/regress.py`, `perf_study.py` | Python drivers |
| `scripts/perf_report.pl` | Perl: parses the logs, writes the summary table and ASCII plot |

## How to run

Needs Verilator (5.050 used here), a C++17 compiler, Python 3, Perl 5. No
RISC-V GCC: programs are written in assembly and built with `tools/assemble.py`.

```sh
make lint                                  # verilator --lint-only -Wall, three parameter sets
make sim PROG=bubble_sort CFG=ic128_bp1    # one program, prints every retired instruction
make regress                               # correctness: 29 programs x 4 configs
make perf                                  # study: 7 benchmarks x 10 configs, RTL + model
make model                                 # C++ model only, all benchmarks at ic128_bp1
make clean
```

- A config is `ic<bytes>_bp<0|1>`: `ic0` = no cache, `ic64`..`ic512` = cache
  size in bytes with 16-byte lines. Other knobs: `MISS_LAT=10`, `SEEDS=5`.
- Each config is a separate Verilator build in `build/<cfg>/` (about 12 s).
- Everything runs one job at a time under low priority (`taskpolicy -b nice`
  on macOS, `nice` elsewhere). `COOL=60` sleeps 60 s after each build.
- Outputs: `results/regress/summary.md` and per-run logs,
  `results/perf/summary.md` and `results/perf/<cfg>/<bench>.log`.
- CI: `.github/workflows/ci.yml` runs lint, regress and perf. It has not been
  run yet (the repo is not on GitHub).

## Benchmarks

| Benchmark | What it stresses |
|---|---|
| `loop` | 200-iteration counted loop, one backward branch |
| `nested_loop` | 16 x 16 loops; the inner exit mispredicts once per outer pass |
| `bubble_sort` | 24 random words; data-dependent swap branch, load-use |
| `linked_list` | 32-node list walked 4 times; pointer chasing, two load-use stalls per step |
| `memcpy` | 64-word copy; load-use on the store data |
| `big_loop` | 384-byte loop body, 8 passes: I-cache **capacity** misses |
| `call_conflict` | two functions 256 B apart called in turn: I-cache **conflict** misses |

## Results (copied from actual runs, macOS, Verilator 5.050)

### `make regress`: 116/116 passed

| Config | Runs | Pass | Retired instructions checked |
|---|---|---|---|
| ic0_bp0 | 29 | 29 | 13327 |
| ic0_bp1 | 29 | 29 | 13327 |
| ic64_bp0 | 29 | 29 | 13327 |
| ic64_bp1 | 29 | 29 | 13327 |

Cover points (summed over all runs): jalr_wrong_target=2, miss_during_lu_stall=76, pred_taken_correct=2582, redirect_during_refill=549

29 programs per config: 7 directed tests, 7 benchmarks, and 15 random
programs (rand_mix, rand_branch, rand_mem x 5 seeds, each body run 3 times so
branches repeat). A run passes only if every retired instruction matches the C
model, no assertion fires, and the counters add up. On `ic0_bp0` the C++ model
must also give the exact RTL cycle count; it did on all 29.

SVA properties (all held on every run):
`a_miss_no_issue` (a fetch that misses never enters the pipeline),
`a_miss_pc_hold` (PC holds during a miss unless redirected),
`a_flush_only_on_mispredict`, `a_mispredict_flushes`, and `a_pred_only_ctrl`
(only branches/jumps are predicted taken). `a_flush_only_on_mispredict`
caught BUGS.md bug 1.

### `make perf`: IPC from the RTL counters

Miss latency 10 cycles, 16-byte lines, BHT 64 entries, BTB 16 entries.
"no cache (ideal)" is the original core's 1-cycle fetch, so it is the upper
bound for any cache size. Mean = geometric mean over the seven benchmarks.

**Predictor off (predict not taken):**

| Benchmark | 64 B | 128 B | 256 B | 512 B | no cache (ideal) |
|---|---|---|---|---|---|
| big_loop | 0.261 | 0.261 | 0.317 | 0.709 | 0.978 |
| bubble_sort | 0.646 | 0.646 | 0.646 | 0.646 | 0.662 |
| call_conflict | 0.150 | 0.217 | 0.217 | 0.587 | 0.667 |
| linked_list | 0.601 | 0.601 | 0.601 | 0.601 | 0.627 |
| loop | 0.588 | 0.588 | 0.588 | 0.588 | 0.600 |
| memcpy | 0.615 | 0.615 | 0.615 | 0.615 | 0.645 |
| nested_loop | 0.664 | 0.664 | 0.664 | 0.664 | 0.677 |
| **mean** | **0.449** | **0.473** | **0.486** | **0.629** | **0.685** |

**Predictor on:**

| Benchmark | 64 B | 128 B | 256 B | 512 B | no cache (ideal) |
|---|---|---|---|---|---|
| big_loop | 0.260 | 0.260 | 0.317 | 0.716 | 0.990 |
| bubble_sort | 0.797 | 0.797 | 0.797 | 0.797 | 0.822 |
| call_conflict | 0.167 | 0.230 | 0.230 | 0.699 | 0.815 |
| linked_list | 0.743 | 0.743 | 0.743 | 0.743 | 0.783 |
| loop | 0.953 | 0.953 | 0.953 | 0.953 | 0.987 |
| memcpy | 0.829 | 0.829 | 0.829 | 0.829 | 0.884 |
| nested_loop | 0.937 | 0.937 | 0.937 | 0.937 | 0.962 |
| **mean** | **0.568** | **0.594** | **0.612** | **0.805** | **0.888** |

```
64 B     BP off |######################                            | 0.449
64 B     BP on  |############################                      | 0.568
128 B    BP off |########################                          | 0.473
128 B    BP on  |##############################                    | 0.594
256 B    BP off |########################                          | 0.486
256 B    BP on  |###############################                   | 0.612
512 B    BP off |###############################                   | 0.629
512 B    BP on  |########################################          | 0.805
ideal    BP off |##################################                | 0.685
ideal    BP on  |############################################      | 0.888
                     0                                              IPC 1.0
```

### Hit, miss and mispredict rates, CPI stack (ic128_bp1)

Miss rate = refills / fetches (wrong-path fetches included). MPKI = misses per 1000 retired.
Mispredict rate = redirects / (branches + jumps). CPI = 1 + bubbles per instruction, by cause.

| Benchmark | I$ miss rate | I$ MPKI | Mispredict (BP off) | Mispredict (BP on) | CPI | I$ | load-use | branch | fill |
|---|---|---|---|---|---|---|---|---|---|
| big_loop | 25.7% | 257.9 | 88.9% | 33.3% | 3.844 | 2.834 | 0.000 | 0.005 | 0.005 |
| bubble_sort | 0.3% | 3.5 | 73.3% | 17.7% | 1.254 | 0.038 | 0.122 | 0.093 | 0.002 |
| call_conflict | 30.2% | 304.5 | 99.0% | 44.6% | 4.347 | 3.119 | 0.000 | 0.218 | 0.010 |
| linked_list | 0.6% | 6.2 | 98.8% | 3.1% | 1.345 | 0.068 | 0.264 | 0.008 | 0.004 |
| loop | 0.3% | 3.3 | 99.5% | 1.5% | 1.050 | 0.036 | 0.000 | 0.007 | 0.007 |
| memcpy | 0.7% | 6.9 | 98.4% | 3.9% | 1.206 | 0.076 | 0.110 | 0.014 | 0.007 |
| nested_loop | 0.4% | 3.7 | 93.8% | 7.3% | 1.068 | 0.029 | 0.000 | 0.035 | 0.004 |

### C++ model vs RTL: IPC error per benchmark and config

| Benchmark | ic0_bp0 | ic0_bp1 | ic64_bp0 | ic64_bp1 | ic128_bp0 | ic128_bp1 | ic256_bp0 | ic256_bp1 | ic512_bp0 | ic512_bp1 | mean abs |
|---|---|---|---|---|---|---|---|---|---|---|---|
| big_loop | +0.0% | +0.0% | +0.0% | +0.7% | +0.0% | +0.7% | +0.0% | +0.4% | +0.0% | +0.0% | 0.2% |
| bubble_sort | +0.0% | +0.0% | -0.1% | -0.1% | -0.1% | -0.1% | -0.1% | -0.1% | -0.1% | -0.1% | 0.1% |
| call_conflict | +0.0% | +0.0% | +25.2% | +18.6% | +23.7% | +25.6% | +23.7% | +25.6% | +2.4% | +2.8% | 14.8% |
| linked_list | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | 0.0% |
| loop | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | 0.0% |
| memcpy | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | 0.0% |
| nested_loop | +0.0% | +0.0% | -0.1% | -0.2% | -0.1% | -0.2% | -0.1% | -0.2% | -0.1% | -0.2% | 0.1% |


Mean absolute IPC error over all 70 runs: 2.2%, worst +25.6%.

### What the numbers say

- **Branch prediction is the bigger win for small-loop code.** With the
  ideal fetch, the predictor raises mean IPC from 0.685 to 0.888 (+30%).
  `loop` goes from 0.600 to 0.987: without a predictor every taken branch
  costs 2 cycles, and the loop is 3 instructions long. The mispredict rate
  falls from 99.5% to 1.5% (the first pass, the loop exit and the halt jump).
- **The I-cache only matters when code does not fit.** Five of the seven
  benchmarks are under 128 bytes of hot code, so their IPC is the same for every
  cache size, 2.5-6% below the ideal fetch (cold misses only).
- **Capacity:** `big_loop` (384 B body) runs at 0.26 IPC with 64-128 B: it
  misses on every line, every pass (25.7% of fetches, 11 cycles each). 256 B
  helps a little (0.317): 8 of its 24 lines have no competitor in the
  direct-mapped cache and stay. 512 B holds it all: 0.716.
- **Conflict:** `call_conflict` touches very little code, but its two
  functions are 256 B apart, so they share an index in every cache up to 256 B
  and evict each other on every call: 0.23 IPC at 128-256 B, 0.70 at 512 B.
- **Prediction helps less when fetch is the bottleneck.** On `big_loop` at
  64 B the predictor changes nothing (0.261 vs 0.260): almost all lost cycles
  are I-cache misses, which a correct guess cannot hide.
- **The predictor has conflicts too.** `call_conflict` still mispredicts 45
  times with the predictor on: the two return `jalr`s are 64 words apart, a
  multiple of the 16-entry BTB, so they share one BTB entry.
- **Model accuracy.** The C++ model is cycle-exact on every benchmark without a
  cache (with or without the predictor). With a cache it is within 0.7% on six
  benchmarks. On `call_conflict` it is 18-26% too optimistic at 64-256 B and under 3% at 512 B (mean absolute error
  over all 70 runs: 2.2%). The reason is wrong-path fetch, which the model does
  not simulate: after a mispredict the RTL fetches 2 wrong instructions; if
  they miss, the refill cannot be cancelled and blocks the correct path. At
  128 B the RTL does 123 refills on `call_conflict`, the model only 82.
  On `bubble_sort` and `nested_loop` the model is 0.1-0.2% pessimistic: there
  a wrong-path refill happens to prefetch a line the correct path needs.

## Limitations

- Only the instruction side is modelled. Data memory is still a 1-cycle
  ideal memory (no D-cache).
- The I-cache is blocking, direct-mapped only, refills a whole line at once
  (no beats, no critical-word-first) and never cancels a refill on a redirect.
- No return-address stack; JALR uses the last target in the BTB.
- The BHT is indexed by PC only (no global history, no gshare).
- Benchmarks are small hand-written assembly programs (no compiler is
  installed), 400 to 2,300 instructions each. They show the effects clearly
  but are not SPEC-like workloads.
- Instruction and data memories are flip-flop arrays (512 and 256 words). The
  RTL is synthesizable and lint-clean (`verilator --lint-only -Wall`), but I
  have not run synthesis or timing on it in this repo.
- The performance model is trace-driven and has no wrong path (see above).
- The CI workflow has not been run.
