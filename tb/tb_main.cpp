// tb_main.cpp : Verilator C++ testbench for riscv_core.
//
//   1. Holds the core in reset and writes the program through the imem_we port.
//   2. Runs the core. Every instruction that retires (rvfi_valid) is checked
//      against the C reference model (model/rv32i_iss.c), one rm_step each.
//   3. Stops when "halt: j halt" (0x0000006f) retires, then reads the
//      performance counters and checks cycles == instret + sum of bubbles.
//
//   Usage: Vcore <program.hex> [+trace] [+max_cycles=N]
//   Output: "PERF key=value ..." and "RESULT PASS|FAIL ..." lines.
#include "Vriscv_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

extern "C" {
void rm_reset(int iwords, int dwords);
void rm_load(int word_addr, int data);
int rm_step(int *pc, int *insn, int *rd_we, int *rd, int *rd_wdata,
            int *mem_we, int *mem_addr, int *mem_wdata);
}

// Must match the riscv_core defaults (IMEM_WORDS, DMEM_WORDS).
static const int IMEM_WORDS = 512, DMEM_WORDS = 256;
static const uint32_t HALT = 0x0000006f;   // jal x0, 0

static const char *PERF_NAMES[] = {"cycles", "instret", "ic_access", "ic_miss", "branches",
                                   "jumps", "mispredicts", "bub_fill", "bub_ic", "bub_lu", "bub_br"};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s program.hex [+trace]\n", argv[0]); return 2; }
    bool trace = false;
    long max_cycles = 200000;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "+trace")) trace = true;
        if (!strncmp(argv[i], "+max_cycles=", 12)) max_cycles = atol(argv[i] + 12);
    }

    std::vector<uint32_t> prog;
    std::ifstream f(argv[1]);
    for (std::string line; std::getline(f, line);)
        if (!line.empty()) prog.push_back((uint32_t)std::stoul(line, nullptr, 16));
    if (prog.empty() || (int)prog.size() > IMEM_WORDS) {
        printf("RESULT FAIL cannot load %s (%zu words)\n", argv[1], prog.size());
        return 1;
    }

    Vriscv_core *top = new Vriscv_core;
    auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };

    // Load while in reset; a few extra reset cycles clear the pipeline.
    top->rst_n = 0;
    rm_reset(IMEM_WORDS, DMEM_WORDS);
    for (size_t i = 0; i < prog.size(); i++) {
        top->imem_we = 1; top->imem_waddr = (uint32_t)i; top->imem_wdata = prog[i];
        tick();
        rm_load((int)i, (int)prog[i]);
    }
    top->imem_we = 0;
    for (int i = 0; i < 3; i++) tick();
    top->rst_n = 1;

    std::string fail;
    long retired = 0, cyc;
    bool halted = false;
    for (cyc = 0; cyc < max_cycles && !halted && fail.empty() && !Verilated::gotFinish(); cyc++) {
        top->clk = 0; top->eval();
        if (top->rvfi_valid) {
            int pc, insn, we, rd, wd, mwe, ma, mwd;
            int rc = rm_step(&pc, &insn, &we, &rd, &wd, &mwe, &ma, &mwd);
            char buf[512];
            snprintf(buf, sizeof buf,
                     "pc=%08x insn=%08x rd_we=%d rd=x%d wdata=%08x mem_we=%d addr=%08x mdata=%08x",
                     top->rvfi_pc, top->rvfi_insn, top->rvfi_rd_we, top->rvfi_rd, top->rvfi_rd_wdata,
                     top->rvfi_mem_we, top->rvfi_mem_addr, top->rvfi_mem_wdata);
            if (trace) printf("COMMIT %6ld %s\n", cyc, buf);
            bool ok = rc == 0 && top->rvfi_pc == (uint32_t)pc && top->rvfi_insn == (uint32_t)insn &&
                      top->rvfi_rd_we == we && (!we || (top->rvfi_rd == rd && top->rvfi_rd_wdata == (uint32_t)wd)) &&
                      top->rvfi_mem_we == mwe &&
                      (!mwe || (top->rvfi_mem_addr == (uint32_t)ma && top->rvfi_mem_wdata == (uint32_t)mwd));
            if (!ok) {
                char exp[256];
                snprintf(exp, sizeof exp,
                         "pc=%08x insn=%08x rd_we=%d rd=x%d wdata=%08x mem_we=%d addr=%08x mdata=%08x rc=%d",
                         pc, insn, we, rd, wd, mwe, ma, mwd, rc);
                fail = "MISMATCH at retire " + std::to_string(retired) + "\n  rtl: " + buf + "\n  ref: " + exp;
            }
            retired++;
            halted = (top->rvfi_insn == HALT);
        }
        top->clk = 1; top->eval();   // counters include this cycle
    }

    uint32_t perf[11];
    for (int i = 0; i < 11; i++) { top->perf_sel = i; top->eval(); perf[i] = top->perf_rdata; }
    printf("PERF");
    for (int i = 0; i < 11; i++) printf(" %s=%u", PERF_NAMES[i], perf[i]);
    printf("\n");

    // Assertion failures end the run through $stop / $fatal.
    if (fail.empty() && Verilated::gotFinish()) fail = "simulation stopped (assertion?)";
    if (fail.empty() && !halted) fail = "TIMEOUT after " + std::to_string(cyc) + " cycles";
    if (fail.empty() && perf[1] != retired)
        fail = "instret counter " + std::to_string(perf[1]) + " != retired " + std::to_string(retired);
    if (fail.empty() && perf[0] != (uint32_t)cyc)
        fail = "cycle counter " + std::to_string(perf[0]) + " != " + std::to_string(cyc);
    if (fail.empty() && perf[0] != perf[1] + perf[7] + perf[8] + perf[9] + perf[10])
        fail = "CPI stack does not add up: cycles != instret + bubbles";

    top->final();
    if (fail.empty()) printf("RESULT PASS retired=%ld cycles=%u\n", retired, perf[0]);
    else printf("RESULT FAIL %s\n", fail.c_str());
    delete top;
    return fail.empty() ? 0 : 1;
}
