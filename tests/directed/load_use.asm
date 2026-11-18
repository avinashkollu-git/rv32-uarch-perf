# Load-use hazards: a load followed immediately by a consumer must stall one
# cycle and then forward from MEM/WB. Covers rs1, rs2, store data, store base,
# branch, jalr and load->load chains. "lw x0" must not stall anything.
        li    x1, 128
        li    x2, 7
        sw    x2, 0(x1)
        li    x3, 132
        sw    x3, 4(x1)
        lw    x4, 0(x1)
        addi  x5, x4, 1         # rs1 load-use
        lw    x6, 0(x1)
        add   x7, x2, x6        # rs2 load-use
        lw    x8, 0(x1)
        sw    x8, 8(x1)         # store data load-use
        lw    x9, 4(x1)
        sw    x2, 4(x9)         # store base load-use (stores 7 at 136)
        lw    x10, 4(x1)
        lw    x11, 0(x10)       # load -> load address chain (x10 = 132, x11 = mem[132] = 132)
        lw    x12, 0(x1)
        beq   x12, x2, t1       # branch load-use, taken
        li    x20, 99
t1:     lw    x13, 0(x1)
        bne   x13, x2, bad      # branch load-use, not taken
        lw    x0, 0(x1)
        addi  x14, x0, 5        # lw x0 must not stall or forward
        lw    x15, 8(x1)
        lw    x15, 0(x1)        # WAW on a load result, then use
        add   x16, x15, x15
        jal   x17, here         # x17 = address of "here"
here:   addi  x17, x17, 24      # x17 = address of "land" (6 words below)
        sw    x17, 12(x1)
        lw    x18, 12(x1)
        jalr  x19, x18, 0       # jalr base from a load (load-use into jalr)
        li    x20, 66           # skipped
        li    x20, 67           # skipped
land:   addi  x21, x19, 0       # x19 = return address of the jalr
        j     halt
bad:    li    x20, 66
halt:   j     halt
