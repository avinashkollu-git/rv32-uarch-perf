# Branch resolution in EX: taken and not-taken for all six conditions, signed
# vs unsigned corners, back-to-back branches, a branch in the shadow of a taken
# branch (must be squashed), and a counted backward loop.
        li    x1, -1            # 0xffffffff
        li    x2, 1
        li    x3, 0
        beq   x2, x2, a1        # taken
        addi  x3, x3, 100       # squashed
a1:     beq   x1, x2, bad       # not taken
        bne   x1, x2, a2        # taken
        addi  x3, x3, 100
a2:     bne   x2, x2, bad       # not taken
        blt   x1, x2, a3        # signed: -1 < 1, taken
        addi  x3, x3, 100
a3:     blt   x2, x1, bad       # not taken
        bltu  x2, x1, a4        # unsigned: 1 < 0xffffffff, taken
        addi  x3, x3, 100
a4:     bltu  x1, x2, bad       # not taken
        bge   x2, x1, a5        # taken
        addi  x3, x3, 100
a5:     bge   x1, x2, bad       # not taken
        bgeu  x1, x2, a6        # taken
        addi  x3, x3, 100
a6:     bgeu  x2, x1, bad       # not taken
        bge   x2, x2, a7        # equal operands: bge taken
        addi  x3, x3, 100
a7:     beq   x2, x2, a8        # taken, and the branch right behind it ...
        beq   x0, x0, bad       # ... sits in the flush shadow and must not redirect
a8:     bne   x0, x0, bad       # back-to-back not-taken branches
        bne   x0, x0, bad
        li    x4, 0             # counted backward loop: 5 iterations
        li    x5, 5
loop:   addi  x4, x4, 1
        addi  x3, x3, 2
        bne   x4, x5, loop
        j     halt
bad:    li    x3, -1
halt:   j     halt
