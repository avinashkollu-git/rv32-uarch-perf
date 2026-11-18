# Tight counted loop: sum = 200 + 199 + ... + 1. One backward branch, taken
# 199 times, not taken once.
        li    x1, 0             # sum
        li    x2, 200           # n
loop:   add   x1, x1, x2
        addi  x2, x2, -1
        bne   x2, x0, loop
        sw    x1, 0(x0)
halt:   j     halt
