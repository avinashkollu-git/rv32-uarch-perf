# JAL/JALR link values (pc+4) forwarded to the very next instructions.
# Before BUGS.md bug 2 was fixed, EX/MEM forwarding sent the ALU result
# instead of the link. It only shows when the instruction after a jump is not
# flushed: a jump to pc+4 (no redirect since bug 1), or a correctly predicted
# call whose target uses ra right away.
        li    x5, 0
        jal   x1, n1            # target = pc+4, no flush
n1:     addi  x2, x1, 0         # EX/MEM forward of the link
        jal   x3, n2
n2:     nop
        addi  x4, x3, 0         # MEM/WB forward of the link
        auipc x6, 0
        jalr  x7, x6, 8         # target = pc+4, no flush
n3:     add   x8, x7, x0        # EX/MEM forward of a jalr link
        li    x9, 4             # call f 4 times: BTB predicts the call and the return
lp:     jal   ra, f
        addi  x9, x9, -1
        bne   x9, x0, lp
        jal   ra, f             # second call site: the BTB still holds the old
        j     halt              # return address, so the return mispredicts its target
f:      addi  x10, ra, 0        # right behind a predicted call
        add   x5, x5, x10
        jalr  x0, ra, 0
halt:   j     halt
