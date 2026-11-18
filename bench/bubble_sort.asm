# Bubble sort of 24 pseudo-random words (xorshift32) stored at 0x100.
# The swap branch depends on the data, so it is hard to predict.
        li    x10, 0x100        # base
        li    x11, 24           # n
        lui   x5, 0x12345       # seed
        addi  x5, x5, 0x678
        li    x6, 0             # i
        mv    x7, x10           # p
init:   slli  x8, x5, 13        # xorshift32
        xor   x5, x5, x8
        srli  x8, x5, 17
        xor   x5, x5, x8
        slli  x8, x5, 5
        xor   x5, x5, x8
        sw    x5, 0(x7)
        addi  x7, x7, 4
        addi  x6, x6, 1
        bne   x6, x11, init
        addi  x12, x11, -1      # end = n - 1
outer:  mv    x7, x10           # p = &a[0]
        li    x6, 0             # j
inner:  lw    x13, 0(x7)
        lw    x14, 4(x7)
        bge   x14, x13, noswap  # a[j+1] >= a[j]: in order (load-use on x14)
        sw    x14, 0(x7)
        sw    x13, 4(x7)
noswap: addi  x7, x7, 4
        addi  x6, x6, 1
        blt   x6, x12, inner
        addi  x12, x12, -1
        bne   x12, x0, outer
halt:   j     halt
