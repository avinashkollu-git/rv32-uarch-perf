# 16 x 16 nested loop: sum += i ^ j. The inner branch is taken 15 times then
# falls through, so a 2-bit counter mispredicts it once per outer iteration.
        li    x5, 0             # sum
        li    x6, 0             # i
        li    x9, 16
outer:  li    x7, 0             # j
inner:  xor   x8, x6, x7
        add   x5, x5, x8
        addi  x7, x7, 1
        bne   x7, x9, inner
        addi  x6, x6, 1
        bne   x6, x9, outer
        sw    x5, 0(x0)
halt:   j     halt
