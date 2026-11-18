# Pointer chasing: 32 nodes {next, value} at 0x200, linked k -> (k+13) mod 32,
# walked 4 times. Each load's address comes from the previous load, so every
# step pays load-use stalls.
        li    x10, 0x200        # base
        li    x6, 0             # k
        li    x11, 32
build:  slli  x7, x6, 3         # &node[k] = base + 8k
        add   x7, x7, x10
        addi  x8, x6, 13        # next index
        andi  x8, x8, 31
        slli  x8, x8, 3
        add   x8, x8, x10
        sw    x8, 0(x7)         # node.next
        sw    x6, 4(x7)         # node.value = k
        addi  x6, x6, 1
        bne   x6, x11, build
        mv    x7, x10           # p = &node[0]
        li    x9, 128           # 4 laps
        li    x12, 0            # sum
walk:   lw    x7, 0(x7)         # p = p->next
        lw    x13, 4(x7)        # load-use: address is the previous load
        add   x12, x12, x13     # load-use again
        addi  x9, x9, -1
        bne   x9, x0, walk
        sw    x12, 0(x0)
halt:   j     halt
