# Bugs found

Every entry here was found by a check in this repo (SVA, the C reference
model compare, or my own check of generated code). Both RTL bugs were fixed
before the commit that added the I-cache and predictor, so they are not in
the git history as separate commits. To reproduce them, undo the one-line
fix in a scratch copy and run the command given.

## RTL bug 1: flush on a "mispredict" that fetched the right path

- **Found by:** SVA `a_flush_only_on_mispredict` (sva/core_sva.sv), first run
  of `tests/directed/jal_jalr.asm` on ic64_bp1:
  `Assertion failed in TOP.riscv_core.u_sva.a_flush_only_on_mispredict`.
- **Trigger:** `jal x12, t3` where `t3` is the next instruction (target = pc+4).
  The predictor said "not taken", so IF fetched pc+4, which is the correct
  instruction. The first version of my redirect logic compared *directions*
  (`taken != pred_taken`), saw a difference, and flushed two correct
  instructions for nothing (2 lost cycles).
- **Root cause:** the mispredict test asked the wrong question. What matters
  is whether the *next PC* was right, not whether the direction was. The
  original core has the same waste (it redirects on every taken jump).
- **Fix:** `rtl/riscv_core.v`: `redirect = idex_valid && (redirect_pc != pred_next)`.
- **Repro:** replace that line with
  `idex_valid && ((ex_taken != idex_pred_taken) || (ex_taken && ex_target != idex_pred_target))`,
  then `make sim PROG=jal_jalr CFG=ic64_bp1`.
- Fixing it exposed bug 2.

## RTL bug 2: wrong value forwarded from a JAL/JALR in EX/MEM (latent in the original core)

- **Found by:** the C reference model compare in the testbench, right after
  fixing bug 1, on `jal_jalr` and `load_use` (ic64_bp1):
  ```
  MISMATCH at retire 14
    rtl: pc=0000003c insn=00060693 rd_we=1 rd=x13 wdata=00000000 ...
    ref: pc=0000003c insn=00060693 rd_we=1 rd=x13 wdata=0000003c ...
  ```
  `addi x13, x12, 0` right after `jal x12, t3` got 0 instead of the link 0x3c.
- **Root cause:** EX/MEM forwarding always sent `exmem_alu_r` (the ALU
  output). A JAL/JALR writes `pc+4`, which only joins the result at the WB
  mux, so MEM/WB forwarding was right but EX/MEM forwarding was wrong. In the
  original core this path was dead: every jump redirected and flushed the two
  younger instructions, so no instruction was ever one behind a jump. Once
  jumps can be predicted (or go to pc+4 with no flush), the next instruction
  sits right behind the jump and reads the bad value.
- **Fix:** `rtl/riscv_core.v`:
  `assign exmem_alu = (exmem_wb_sel == WB_PC4) ? exmem_pc4 : exmem_alu_r;`
- **Regression test:** `tests/directed/link_forward.asm` (EX/MEM and MEM/WB
  forwarding of JAL and JALR links, and a predicted call whose target reads
  `ra` at once).
- **Repro:** put back `assign exmem_alu = exmem_alu_r;` and run
  `make sim PROG=link_forward CFG=ic0_bp1`.
- **Lesson:** a new feature can make a path reachable that earlier tests could
  never reach, so old "100% line coverage" did not mean that path was right.
  The bad value was on a covered line; only the combination (jump + dependent
  instruction, no flush) was new.

## Tool bug 3: benchmark generator placed a function 4 bytes off

- **Found by:** checking the assembled words of `bench/call_conflict.asm`
  against the intended addresses: `fa` was at 0x144, not 0x140.
- **Root cause:** `tools/gen_bench.py` padded with NOPs by counting indented
  lines; `loop:   jal ra, fa` had the label on the same line, so it was not
  counted and one extra NOP was added. At 0x144 the experiment still ran, but
  the "exactly 256 bytes apart" claim in the README would have been false.
- **Fix:** labels go on their own line in the generator. Checked after the
  fix: the word at 0x140 is `addi x5, x5, 1` (fa) and at 0x240 `addi x5, x5, 100` (fb).

## Not bugs, but model-vs-RTL differences

The C++ model is cycle-exact without the I-cache (make regress checks every
program on ic0_bp0). With the I-cache its error comes from wrong-path
fetches, which it does not model. See the README for numbers.
