#!/usr/bin/env python3
"""Constrained-random RV32I program generator for the rv32 core.

Every program:
  - starts by loading random values into x1..x29 and a data base into x31,
  - is followed by a random body whose instruction mix depends on the test,
  - ends with "halt: j halt" (the testbench stops when it retires).
  - with --loops N, the random body runs N times inside a counted loop (x28
    is the counter and is never a random destination), so the branch
    predictor sees each branch again, with new register values each time.

Constraints that keep programs legal and terminating:
  - branches and jumps only go forward, so every program halts,
  - load/store addresses are naturally aligned and inside data memory,
  - x30 is reserved for auipc+jalr pairs and x31 for the data base, so random
    instructions never write them,
  - sources are biased toward registers written by the last few instructions,
    which creates back-to-back RAW and load-use hazards on purpose.

Usage: rvgen.py --test rand_mix --seed 7 --out build/t.asm   (writes .asm and .hex)
"""
import argparse, os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from assemble import assemble

IMEM_WORDS = 512       # must match riscv_core IMEM_WORDS
DATA_BASE = 0x200      # x31; offsets -512..508 keep addresses in 0..1020 (256 words)

R_OPS = ["add", "sub", "and", "or", "xor", "sll", "srl", "sra", "slt", "sltu"]
I_OPS = ["addi", "andi", "ori", "xori", "slti", "sltiu"]
SH_OPS = ["slli", "srli", "srai"]
BR_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]

# instruction-class weights per test
MIXES = {
    "rand_alu":    dict(alu_r=45, alu_i=40, upper=15),
    "rand_mem":    dict(alu_r=20, alu_i=15, load=35, store=30),
    "rand_branch": dict(alu_r=25, alu_i=25, branch=30, jal=10, jalr=10),
    "rand_mix":    dict(alu_r=20, alu_i=20, upper=5, load=15, store=12, branch=15, jal=6, jalr=7),
}

class Gen:
    def __init__(self, seed, mix, n, loops=1):
        self.r = random.Random(seed)
        self.mix, self.n, self.loops = mix, n, loops
        self.max_rd = 27 if loops > 1 else 29   # x28 is the loop counter
        self.lines, self.recent = [], []
        self.pending = []          # [label, instructions still to emit before it]
        self.single_only = 0       # after a jalr, keep items 1 instruction long
        self.nlab = 0

    def emit(self, text):
        self.lines.append("        " + text)
        for p in self.pending:
            p[1] -= 1

    def place_labels(self):
        # labels go only on item boundaries, never inside an auipc+jalr pair
        for p in [p for p in self.pending if p[1] <= 0]:
            self.lines.append(p[0] + ":")
            self.pending.remove(p)

    def label(self, skip):
        self.nlab += 1
        name = f"L{self.nlab}"
        self.pending.append([name, skip + 1])   # +1: the branch's own emit counts down too
        return name

    def rd(self):
        r = self.r.randint(1, self.max_rd)
        self.recent = ([r] + self.recent)[:3]
        return r

    def rs(self):
        # 60%: a register written by one of the last 3 instructions (hazard)
        if self.recent and self.r.random() < 0.6:
            return self.r.choice(self.recent)
        return self.r.randint(0, 31)

    def item(self, kind):
        r = self.r
        if kind == "alu_r":
            s1, s2 = self.rs(), self.rs()
            self.emit(f"{r.choice(R_OPS)} x{self.rd()}, x{s1}, x{s2}")
        elif kind == "alu_i":
            s1 = self.rs()
            if r.random() < 0.3:
                self.emit(f"{r.choice(SH_OPS)} x{self.rd()}, x{s1}, {r.randint(0, 31)}")
            else:
                imm = r.choice([0, 1, -1, 2047, -2048, r.randint(-2048, 2047)])
                self.emit(f"{r.choice(I_OPS)} x{self.rd()}, x{s1}, {imm}")
        elif kind == "upper":
            self.emit(f"{r.choice(['lui', 'auipc'])} x{self.rd()}, {r.randint(0, 0xfffff)}")
        elif kind in ("load", "store"):
            op, size = r.choice([("lb", 1), ("lbu", 1), ("lh", 2), ("lhu", 2), ("lw", 4)] if kind == "load"
                                else [("sb", 1), ("sh", 2), ("sw", 4)])
            # naturally aligned, inside the 1 KiB data memory
            if r.random() < 0.7:
                base, off = 31, size * r.randint(-512 // size, 511 // size)
            else:
                base, off = 0, size * r.randint(0, 1023 // size)
            if kind == "load":
                self.emit(f"{op} x{self.rd()}, {off}(x{base})")
            else:
                self.emit(f"{op} x{self.rs()}, {off}(x{base})")
        elif kind == "branch":
            s1, s2 = self.rs(), self.rs()
            self.emit(f"{r.choice(BR_OPS)} x{s1}, x{s2}, {self.label(r.randint(1, 4))}")
        elif kind == "jal":
            link = r.choice([0, 1, self.rd()])
            self.emit(f"jal x{link}, {self.label(r.randint(1, 3))}")
        elif kind == "jalr":
            # auipc x30 = P; jalr at P+4 jumps to P+8+4k (k items skipped).
            # An odd offset checks that jalr clears bit 0 of the target.
            k = r.randint(0, 3)
            link = r.choice([0, 1, self.rd()])
            self.emit("auipc x30, 0")
            self.emit(f"jalr x{link}, x30, {8 + 4 * k + r.choice([0, 1])}")
            self.single_only = k   # target must land on an item boundary

    def body(self):
        kinds, weights = zip(*self.mix.items())
        for v in range(1, 30):    # random register file
            self.emit(f"lui x{v}, {self.r.randint(0, 0xfffff)}")
            self.emit(f"addi x{v}, x{v}, {self.r.randint(-2048, 2047)}")
        self.emit(f"li x31, {DATA_BASE}")
        if self.loops > 1:
            self.emit(f"li x28, {self.loops}")
            self.lines.append("top:")
        for _ in range(self.n):
            self.place_labels()
            k = self.r.choices(kinds, weights)[0]
            if self.single_only:
                self.single_only -= 1
                if k == "jalr":
                    k = "alu_r"
            self.item(k)
        for _ in range(self.single_only):   # a jalr near the end still needs its landing pad
            self.emit("nop")
        while self.pending:       # forward targets past the end land on halt
            self.emit("nop")
            self.place_labels()
        if self.loops > 1:
            self.emit("addi x28, x28, -1")
            self.emit("bne x28, x0, top")
        self.lines.append("halt:   j halt")
        return "\n".join(self.lines) + "\n"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test", required=True, choices=sorted(MIXES))
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--n", type=int, default=150, help="random body items")
    ap.add_argument("--loops", type=int, default=1, help="run the random body this many times")
    ap.add_argument("--out", required=True, help="output .asm path (.hex written next to it)")
    a = ap.parse_args()
    src = Gen(a.seed, MIXES[a.test], a.n, a.loops).body()
    words = assemble(src)
    assert len(words) <= IMEM_WORDS, f"program too long: {len(words)} words"
    open(a.out, "w").write(f"# rvgen.py --test {a.test} --seed {a.seed} --n {a.n} --loops {a.loops}\n" + src)
    with open(os.path.splitext(a.out)[0] + ".hex", "w") as f:
        f.writelines(f"{w:08x}\n" for w in words)

if __name__ == "__main__":
    main()
