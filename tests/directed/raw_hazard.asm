# Back-to-back RAW hazards: every consumer reads a register written 1, 2 or 3
# instructions earlier, so the EX/MEM path, the MEM/WB path and the regfile
# write-then-read path (negedge write) are all used. Checked against the C model.
        li    x1, 5
        addi  x2, x1, 1         # rs1 from EX/MEM (distance 1)
        add   x3, x1, x2        # rs1 from MEM/WB (dist 2), rs2 from EX/MEM (dist 1)
        add   x4, x3, x3        # both operands from EX/MEM
        sub   x5, x4, x1        # rs1 EX/MEM; x1 from regfile
        add   x5, x5, x5        # rd == rs1 == rs2, chained
        add   x5, x5, x5
        xor   x6, x2, x5        # dist 3 (regfile, written same cycle at negedge)
        add   x0, x1, x1        # write to x0 must be dropped ...
        add   x7, x0, x0        # ... and never forwarded: x7 = 0
        addi  x8, x0, 64
        sw    x5, 0(x8)         # store data forwarded (dist 4 -> regfile), base EX/MEM
        addi  x9, x5, 3
        sw    x9, 4(x8)         # store data from EX/MEM
        addi  x10, x8, 8
        sw    x10, 0(x10)       # base and data both from EX/MEM
        lw    x11, 0(x8)
        lw    x12, 4(x8)
        lw    x13, 8(x8)
        lui   x14, 0x12345
        addi  x14, x14, 0x678   # lui -> addi forwarding
        auipc x15, 1
        addi  x15, x15, -4      # auipc -> addi forwarding
        addi  x16, x1, 0
        beq   x16, x1, ok1      # branch comparator uses forwarded rs1
        li    x20, 1
ok1:    addi  x17, x0, 2
        bne   x17, x16, ok2     # forwarded rs1 vs regfile rs2
        li    x20, 2
ok2:    addi  x18, x0, 3
        slli  x18, x18, 2
        or    x19, x18, x17
halt:   j     halt
