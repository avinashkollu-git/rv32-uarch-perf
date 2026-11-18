# JAL / JALR: link value (pc+4), target computation, LSB clearing on jalr,
# rd == rs1 on jalr (target must use the old rs1), jalr base produced by the
# instruction right before it (EX/MEM forward), and a call/return pair.
        li    x10, 0
        jal   x1, f1            # call
        addi  x10, x10, 1       # executes after return
        jal   x0, skip1         # plain jump, no link
        addi  x10, x10, 100     # squashed
skip1:  auipc x5, 0             # x5 = address of this auipc
        jalr  x6, x5, 13        # (x5+13)&~1 = x5+12 -> lands on t1 (LSB cleared)
        addi  x10, x10, 100     # skipped
t1:     addi  x10, x10, 2
        auipc x7, 0
        addi  x7, x7, 16        # x7 = address of t2
        jalr  x7, x7, 0         # rd == rs1, base forwarded from EX/MEM
        addi  x10, x10, 100     # skipped
t2:     addi  x11, x7, 0        # x7 now holds the link (pc of jalr + 4)
        jal   x12, t3
t3:     addi  x13, x12, 0       # link of a jal to the next instruction
        j     halt
f1:     addi  x10, x10, 10
        jalr  x0, x1, 0         # return
halt:   j     halt
