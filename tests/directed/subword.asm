# Byte and halfword loads/stores: every lane, sign vs zero extension, a
# sub-word store merged into an existing word, and load-use on a sub-word load.
        li    x1, 256
        lui   x2, 0x81828
        addi  x2, x2, 0x384     # x2 = 0x81828384
        sw    x2, 0(x1)
        lb    x3, 0(x1)         # 0xffffff84 (sign)
        lbu   x4, 0(x1)         # 0x00000084
        lb    x5, 1(x1)         # 0xffffff83
        lbu   x6, 3(x1)         # 0x00000081
        lh    x7, 0(x1)         # 0xffff8384
        lhu   x8, 2(x1)         # 0x00008182
        li    x9, 0x55
        sb    x9, 1(x1)         # word = 0x81825584
        sb    x9, 3(x1)         # word = 0x55825584
        lw    x10, 0(x1)
        li    x11, -2
        sh    x11, 2(x1)        # word = 0xfffe5584
        lw    x12, 0(x1)
        sh    x9, 0(x1)         # word = 0xfffe0055
        lhu   x13, 0(x1)
        addi  x14, x13, 1       # load-use on a halfword load
        lb    x15, 2(x1)
        sb    x15, 4(x1)        # load-use: byte load -> byte store data
        lw    x16, 4(x1)
halt:   j     halt
