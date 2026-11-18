# Interview notes

Plain-English notes on the ideas behind this project, using this core's
numbers as examples. Results tables are in the README.

## 1. Caches

**Why a cache.** Main memory is slow (here: 10 cycles to return a line). Most
programs reuse a small amount of code and data again and again (temporal
locality) and use neighbours of what they just used (spatial locality). A small,
fast memory that keeps recently used lines gives most accesses at 1-cycle speed.

**Line (block).** The unit the cache moves: here 16 bytes = 4 instructions. One
miss brings in 4 instructions, so a straight-line run of code misses once per
4 instructions at most (spatial locality).

**Address split.** For a direct-mapped cache with L lines of B bytes:
`offset = log2(B)` bits, `index = log2(L)` bits, `tag` = the rest. The index
picks the one line the address can live in; the stored tag says which of the
many addresses with that index is in it now; a valid bit says the line holds
anything at all. Hit = valid and tag matches.

**Direct-mapped vs set-associative.**
- Direct-mapped: each address has exactly one place. Fast and cheap (one tag
  compare, no replacement choice) but two hot addresses with the same index
  keep evicting each other.
- N-way set-associative: the index picks a *set* of N lines; the address can
  go in any of them. N tag compares in parallel, plus a replacement policy
  (LRU, pseudo-LRU, random). Fewer conflict misses, more area, power and
  often a slower hit.
- Fully associative: one set, any line anywhere. No conflict misses; only
  practical for small structures (TLBs, small BTBs).

**Hit / miss.** Hit: data comes out this cycle. Miss: the pipeline stalls, the
cache asks memory for the whole line, writes it with its tag and valid bit,
then the access is retried and hits. Here a miss costs `1 + MISS_LAT` = 11
fetch cycles (one cycle to detect the miss, ten to get the line).

**AMAT (average memory access time).**
`AMAT = hit time + miss rate x miss penalty`.
Example: hit 1 cycle, miss rate 5%, penalty 11 -> 1 + 0.05 x 11 = 1.55 cycles.
Halving the miss rate (to 2.5%) gives 1.275. Halving the penalty gives the
same. That is why both bigger caches and faster memory (or a second-level
cache) help.

**The 3 Cs (why misses happen).**
- *Compulsory* (cold): first touch of a line. Happens even with an infinite
  cache. Every benchmark here has a few (the I-cache starts empty).
  Fix: bigger lines, prefetching.
- *Capacity*: the working set does not fit. `big_loop` has a 384-byte loop
  body; a 64-256 B cache misses on almost every line every iteration, 512 B
  holds it all. Fix: a bigger cache.
- *Conflict*: it would fit, but two addresses fight for the same index.
  `call_conflict` calls two 32-byte functions 256 bytes apart: in a 64-256 B
  direct-mapped cache they share an index and evict each other on every call,
  though together they are tiny. Fix: associativity, or move the code.
- (A 4th C, *coherence*, exists for multi-core data caches; not relevant here.)

## 2. Branch prediction

**The problem.** This pipeline knows a branch's direction and target only in
EX, the 3rd stage. By then IF and ID already hold two younger instructions.
If they are the wrong ones, they are flushed: 2 lost cycles. Without a
predictor the core always fetches pc+4 ("predict not taken"), so every taken
branch and every jump costs 2 cycles.

**BTB (branch target buffer).** A small cache indexed by the fetch PC that
remembers "the instruction at this PC is a branch/jump, and last time it went
to this target". Without it, even a correct "taken" guess is useless in IF,
because the target is not computed yet. Here: 16 entries, tagged, holding the
target and an "unconditional jump" bit.

**2-bit saturating counter (BHT).** One counter per entry, 0..3. Taken -> +1,
not taken -> -1, stuck at the ends. Predict taken if the counter is 2 or 3.
Why 2 bits and not 1: a loop branch is taken N-1 times then not taken once.
A 1-bit predictor mispredicts twice per loop (the exit, and the first
iteration of the next run). A 2-bit counter only drops from 3 to 2 on the exit,
so it still predicts taken next time: 1 mispredict per loop. Here: 64 entries,
untagged (two branches can share a counter: aliasing).

**Predict in IF, resolve in EX.** IF looks up BTB + BHT with the PC and sends
the predicted next PC to the PC register at once. The guess travels down the
pipe with the instruction. In EX the real next PC is computed; if it differs
from the guess, IF/ID and ID/EX are flushed and the PC is set to the right
value. The BHT/BTB are updated in EX.

**Misprediction penalty.** Here 2 cycles (resolve stage 3, minus 1). In a
deep out-of-order core it is 15-20+ cycles, which is why prediction accuracy
matters so much there. JALR (function return) targets change from call site
to call site; a BTB only remembers the last one. Real cores add a
return-address stack.

## 3. Pipeline CPI math

**Ideal.** A 5-stage pipeline can finish one instruction per cycle: CPI = 1,
IPC = 1. Real CPI = 1 + stall cycles per instruction:

`CPI = 1 + (load-use stalls + branch penalties + I-cache stalls) / instructions`

- load-use: `f_lu x 1` (fraction of instructions that use a load result right away)
- branches: `f_branch x mispredict rate x 2`
- I-cache: `misses per instruction x (1 + MISS_LAT)` (minus any overlap)

Example: 20% branches, 10% mispredicted -> 0.2 x 0.1 x 2 = 0.04 CPI. Without a
predictor, 60% of branches taken -> 0.2 x 0.6 x 2 = 0.24 CPI.

**CPI stack in this RTL.** Each bubble is tagged with why it was created (cold
start, I-cache miss, load-use, branch flush). When a bubble reaches WB, its
counter goes up. Every cycle WB holds either an instruction or one bubble, so
`cycles = instret + sum of bubble counters`, exactly. The testbench checks
this identity every run. When two hazards overlap (an I-cache miss during a
branch flush), the bubble is charged once, to the one that created it last.

**Amdahl's law.** Speedup from improving one part is limited by how much time
that part takes. If I-cache stalls are 10% of cycles, a perfect I-cache gives
at most 1/0.9 = 1.11x.

## 4. Why a performance model differs from the RTL

- **Abstraction on purpose.** A model is written to run fast and to explore
  designs before RTL exists. It leaves out detail that is expensive to model
  and (hopefully) small in effect.
- **What mine leaves out:** wrong-path fetch. After a mispredicted branch, the
  RTL keeps fetching for 2 cycles down the wrong path. If those fetches miss,
  the RTL starts a refill that cannot be cancelled. That refill can (a) block
  the correct-path fetch for up to 11 cycles, (b) evict a line that is needed
  soon, or (c) bring in a line that is needed later (a free prefetch). The
  model sees only the correct path. That is why it is cycle-exact with no
  cache and off by up to tens of percent on `call_conflict`.
- **Timing detail.** Predictor updates happen in EX; a lookup two cycles
  later sees them, but a lookup one cycle later does not. I model this with a
  small queue of pending updates. Leaving it out gives a different answer for
  very tight loops.
- **Counting differences.** "Miss rate" in the RTL counts wrong-path fetches
  too; the model only counts correct-path ones. Always check that the model
  and RTL define a counter the same way before comparing.
- **How teams use this.** Correlate the model against RTL on a set of
  benchmarks, report the error, and fix the model where the error is large
  and the effect matters for a decision. A model with 5% error is fine for
  "is 256 B or 512 B better", not for sign-off timing.

## 5. Likely interview questions

**Q1. What is the miss penalty in your design and how did you measure it?**
11 fetch cycles: 1 to detect, 10 (`MISS_LAT`) to get the line. The I-cache
bubble counter divided by the miss count gives about this, a little less
because some bubbles are overwritten by branch flushes and charged to branches.

**Q2. Why is your BHT untagged but your BTB tagged?**
A wrong BHT counter only gives a bad direction guess, which EX corrects.
A wrong BTB hit would predict "taken" for a non-branch and jump to a random
target. That is also corrected in EX, but it would cost 2 cycles on ordinary
instructions. Tags on a 16-entry BTB are cheap; tags on the BHT would cost
more than the accuracy they buy.

**Q3. Why does a 2-bit counter beat a 1-bit one on loops?**
Hysteresis. A loop exit is one not-taken among many taken. With 2 bits the
counter goes 3 -> 2 and still predicts taken next time; with 1 bit it flips
and mispredicts the first iteration of the next run too.

**Q4. big_loop's body is 384 bytes. Why does a 256 B cache still help it (IPC 0.261 -> 0.317)?**
The body is 24 lines; a 256 B cache has 16. Sweeping 24 lines through 16
direct-mapped slots, lines 16-23 evict lines 0-7, but lines 8-15 have no
competitor and stay. So a third of the lines hit every iteration. With LRU in
a fully associative 16-line cache, a sequential sweep larger than the cache
would miss every line, so here direct-mapped is actually better than LRU.

**Q5. What would you change first to improve IPC here?**
Look at the CPI stack. For I-cache-bound code (big_loop, call_conflict) a
bigger or 2-way cache; for pointer-chasing (linked_list), load-use stalls
dominate, so a cache will not help: you need a different schedule or an
out-of-order core. Always measure where the cycles go before choosing.

**Q6. How did you verify the cache and predictor are correct?**
They are performance features, so they must never change results. Every
retired instruction is compared with a C reference model through the retire
trace, on 4 configs (each feature on/off). SVA checks the rules (a missed
fetch never enters the pipe, PC holds during a miss, flush only on a real
mispredict, every real mispredict flushes, only branches are predicted
taken). Cover points prove the corner cases happen (miss during a load-use
stall, redirect during a refill, wrong JALR target).

**Q7. What is the difference between a stall and a flush?**
A stall holds instructions in place and inserts a bubble behind them
(load-use: PC and IF/ID hold, ID/EX gets a bubble). A flush throws away
instructions that should not run (mispredict: IF/ID and ID/EX become
bubbles). Stalls keep work; flushes discard it.

**Q8. Why might the model be optimistic or pessimistic?**
Optimistic when a wrong-path refill blocks the correct-path fetch in the RTL
(model has no wrong path, so no block). Pessimistic when a wrong-path refill
acts as a prefetch. Here: up to +25.6% optimistic on call_conflict (RTL makes
123 refills where the model counts 82 at 128 B), and -0.1 to -0.2% pessimistic
on bubble_sort and nested_loop (a wrong-path fetch happens to prefetch).

**Bonus: why does call_conflict still mispredict 45 times with the predictor on?**
The two returns (`jalr` at 0x15c and 0x25c) are 64 words apart, a multiple of
the 16-entry BTB, so they share a BTB entry and evict each other on every
call: a conflict miss in the predictor, the same "C" as in the cache.

**Q9. How would you make the I-cache non-blocking?**
Allow hits while a refill is in flight (hit-under-miss), cancel or ignore a
refill when the PC is redirected, return the requested word first
(critical-word-first) and restart fetch early. Each one needs more state and
more verification (e.g. a refill must not overwrite a line that was just
filled by another request).

**Q10. What is AMAT for your design on big_loop at 64 B vs 512 B?**
Measured with the predictor on: 64 B has 205 misses in 799 fetches (25.7%),
so AMAT = 1 + 0.257 x 11 = 3.8 cycles per fetch. 512 B has 28 misses in 800
fetches (3.5%, almost all cold), AMAT = 1 + 0.035 x 11 = 1.4. IPC goes from
0.260 to 0.716, close to the AMAT ratio, because fetch is nearly all of the
stall time in this benchmark.

**Q11. Why does branch prediction help less when the I-cache is small?**
When most cycles are I-cache stalls, the 2 cycles saved per branch are a small
part of the total. Also, a predicted-taken branch jumps to a target line that
may not be in the cache, so it saves the flush but still waits for a refill.

**Q12. How would you scale this to a real CPU performance team flow?**
A fast functional + timing model (like my C++ model, but with more detail)
runs many workloads; RTL runs a few; counters from both are correlated, and
the gaps are explained or fixed. Design choices (cache size, ways, predictor
type) are made on the model; the RTL proves they are buildable and correct.
