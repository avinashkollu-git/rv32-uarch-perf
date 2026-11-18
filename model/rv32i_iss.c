// rv32i_iss.c : tiny RV32I instruction-set simulator used as the golden
//   reference model. The testbench calls it through DPI-C: rm_reset/rm_load to
//   mirror the program, then rm_step once per instruction the RTL retires and
//   compares pc, rd, write data and store address/data.
//
//   It models exactly what the core claims to implement: RV32I integer ops
//   and loads/stores of all widths, on word-addressed memories that wrap at
//   their size (the RTL uses "addr % WORDS"). Anything else (FENCE, ECALL,
//   CSR, M extension, ...) is reported as illegal, and misaligned accesses as
//   misaligned, instead of guessed: the core has no traps, so the generator
//   never produces them.
//   For a store, the trace reports the whole memory word after the write, so
//   the byte-lane merge is checked too.
#include <stdint.h>
#include <string.h>
#include <stdio.h>

#ifdef __cplusplus   // Verilator builds .c files with the C++ compiler
extern "C" {
#endif

#define MAX_WORDS 4096

static uint32_t x[32], pc, imem[MAX_WORDS], dmem[MAX_WORDS];
static uint32_t imem_words, dmem_words;

// Return codes of rm_step.
enum { RM_OK = 0, RM_ILLEGAL = 1, RM_MISALIGNED = 2 };

static int32_t sext(uint32_t v, int bits) { return (int32_t)(v << (32 - bits)) >> (32 - bits); }

void rm_reset(int iwords, int dwords) {
    imem_words = (uint32_t)iwords; dmem_words = (uint32_t)dwords;
    memset(x, 0, sizeof x); memset(imem, 0, sizeof imem); memset(dmem, 0, sizeof dmem);
    pc = 0;
}

void rm_load(int word_addr, int data) { imem[(uint32_t)word_addr % imem_words] = (uint32_t)data; }

int rm_get_reg(int r) { return (int)x[r & 31]; }

int rm_step(int *o_pc, int *o_insn, int *o_rd_we, int *o_rd, int *o_rd_wdata,
            int *o_mem_we, int *o_mem_addr, int *o_mem_wdata) {
    uint32_t in = imem[(pc >> 2) % imem_words];
    uint32_t op = in & 0x7f, rd = (in >> 7) & 31, f3 = (in >> 12) & 7;
    uint32_t rs1 = (in >> 15) & 31, rs2 = (in >> 20) & 31, f7 = in >> 25;
    uint32_t a = x[rs1], b = x[rs2], next = pc + 4, res = 0;
    int32_t imm_i = sext(in >> 20, 12);
    int32_t imm_s = sext(((in >> 25) << 5) | ((in >> 7) & 31), 12);
    int32_t imm_b = sext(((in >> 31) << 12) | (((in >> 7) & 1) << 11) |
                         (((in >> 25) & 0x3f) << 5) | (((in >> 8) & 0xf) << 1), 13);
    int32_t imm_j = sext(((in >> 31) << 20) | (((in >> 12) & 0xff) << 12) |
                         (((in >> 20) & 1) << 11) | (((in >> 21) & 0x3ff) << 1), 21);
    int wr = 1, rc = RM_OK;

    *o_pc = (int)pc; *o_insn = (int)in; *o_mem_we = 0; *o_mem_addr = 0; *o_mem_wdata = 0;

    switch (op) {
    case 0x33: // R-type
        if (f7 != 0x00 && !(f7 == 0x20 && (f3 == 0 || f3 == 5))) { rc = RM_ILLEGAL; wr = 0; break; }
        switch (f3) {
        case 0: res = f7 ? a - b : a + b; break;
        case 1: res = a << (b & 31); break;
        case 2: res = (int32_t)a < (int32_t)b; break;
        case 3: res = a < b; break;
        case 4: res = a ^ b; break;
        case 5: res = f7 ? (uint32_t)((int32_t)a >> (b & 31)) : a >> (b & 31); break;
        case 6: res = a | b; break;
        case 7: res = a & b; break;
        }
        break;
    case 0x13: { // I-type ALU
        uint32_t i = (uint32_t)imm_i, sh = i & 31;
        switch (f3) {
        case 0: res = a + i; break;
        case 1: res = a << sh; break;
        case 2: res = (int32_t)a < imm_i; break;
        case 3: res = a < i; break;
        case 4: res = a ^ i; break;
        case 5: res = (in >> 30) & 1 ? (uint32_t)((int32_t)a >> sh) : a >> sh; break;
        case 6: res = a | i; break;
        case 7: res = a & i; break;
        }
        break; }
    case 0x03: { // LB LH LW LBU LHU
        uint32_t ad = a + (uint32_t)imm_i, size = 1u << (f3 & 3);
        uint32_t lane = dmem[(ad >> 2) % dmem_words] >> (8 * (ad & 3));
        if (f3 == 3 || f3 > 5) { rc = RM_ILLEGAL; wr = 0; break; }
        if (ad & (size - 1)) rc = RM_MISALIGNED;
        switch (f3) {
        case 0: res = (uint32_t)sext(lane & 0xff, 8); break;
        case 1: res = (uint32_t)sext(lane & 0xffff, 16); break;
        case 2: res = lane; break;
        case 4: res = lane & 0xff; break;
        case 5: res = lane & 0xffff; break;
        }
        break; }
    case 0x23: { // SB SH SW
        uint32_t ad = a + (uint32_t)imm_s, size = 1u << f3, sh = 8 * (ad & 3);
        uint32_t *w = &dmem[(ad >> 2) % dmem_words];
        uint32_t mask = size == 4 ? 0xffffffffu : ((1u << (8 * size)) - 1) << sh;
        wr = 0;
        if (f3 > 2) { rc = RM_ILLEGAL; break; }
        if (ad & (size - 1)) rc = RM_MISALIGNED;
        *w = (*w & ~mask) | ((b << sh) & mask);
        *o_mem_we = 1; *o_mem_addr = (int)ad; *o_mem_wdata = (int)*w;
        break; }
    case 0x63: { // branches
        int t;
        wr = 0;
        switch (f3) {
        case 0: t = a == b; break;
        case 1: t = a != b; break;
        case 4: t = (int32_t)a < (int32_t)b; break;
        case 5: t = (int32_t)a >= (int32_t)b; break;
        case 6: t = a < b; break;
        case 7: t = a >= b; break;
        default: t = 0; rc = RM_ILLEGAL;
        }
        if (t) next = pc + (uint32_t)imm_b;
        break; }
    case 0x6f: res = pc + 4; next = pc + (uint32_t)imm_j; break;            // JAL
    case 0x67: res = pc + 4; next = (a + (uint32_t)imm_i) & ~1u; break;     // JALR
    case 0x37: res = in & 0xfffff000u; break;                               // LUI
    case 0x17: res = pc + (in & 0xfffff000u); break;                        // AUIPC
    default: rc = RM_ILLEGAL; wr = 0;
    }

    if (next & 3) rc = RM_MISALIGNED;   // RV32I without C: jump target must be 4-byte aligned
    *o_rd_we = wr && rd != 0;
    *o_rd = (int)rd;
    *o_rd_wdata = *o_rd_we ? (int)res : 0;
    if (*o_rd_we) x[rd] = res;
    pc = next;
    return rc;
}

#ifdef __cplusplus
}
#endif

#ifdef ISS_SELFTEST
// Build: cc -DISS_SELFTEST hvl/dpi/rv32i_iss.c && ./a.out
#include <assert.h>
int main(void) {
    int p, i, we, rd, wd, mwe, ma, mwd, n = 0;
    uint32_t prog[] = {
        0x00f00093, // addi x1, x0, 15
        0xff000113, // addi x2, x0, -16
        0x401151b3, // sra  x3, x2, x1   -> -1
        0x0020a233, // slt  x4, x1, x2   -> 0
        0x00102023, // sw   x1, 0(x0)
        0x00002283, // lw   x5, 0(x0)    -> 15
        0x00508463, // beq  x1, x5, +8   (taken)
        0x00100313, // addi x6, x0, 1    (skipped)
        0x008003ef, // jal  x7, +8       -> x7 = pc+4 = 0x24
        0x00000013, // nop (skipped)
        0xfff00413, // addi x8, x0, -1
        0x008000a3, // sb   x8, 1(x0)    -> mem[0] = 0x0000ff0f
        0x00100483, // lb   x9, 1(x0)    -> -1
        0x00104503, // lbu  x10, 1(x0)   -> 0xff
        0x00001583, // lh   x11, 0(x0)   -> 0xffffff0f
        0x0000006f, // j .  (halt)
    };
    rm_reset(256, 256);
    for (unsigned k = 0; k < sizeof prog / 4; k++) rm_load(k, prog[k]);
    while (n++ < 20) { assert(rm_step(&p, &i, &we, &rd, &wd, &mwe, &ma, &mwd) == RM_OK); if (i == 0x6f) break; }
    assert(x[1] == 15 && x[3] == 0xffffffffu && x[4] == 0 && x[5] == 15 && x[6] == 0 && x[7] == 0x24);
    assert(dmem[0] == 0x0000ff0f && x[9] == 0xffffffffu && x[10] == 0xff && x[11] == 0xffffff0fu);
    printf("rv32i_iss selftest: PASS (%d steps)\n", n);
    return 0;
}
#endif
