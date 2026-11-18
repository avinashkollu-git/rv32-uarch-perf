# memcpy of 64 words from 0x000 to 0x200, one word per iteration. The store
# needs the loaded word right away, so each iteration has a load-use stall.
        li    x6, 0             # fill the source: src[i] = 3i
        li    x8, 0
        li    x11, 0x100        # source end
fill:   sw    x8, 0(x6)
        addi  x8, x8, 3
        addi  x6, x6, 4
        bne   x6, x11, fill
        li    x10, 0            # src
        li    x12, 0x200        # dst
copy:   lw    x13, 0(x10)
        sw    x13, 0(x12)       # load-use on the store data
        addi  x10, x10, 4
        addi  x12, x12, 4
        bne   x10, x11, copy
halt:   j     halt
