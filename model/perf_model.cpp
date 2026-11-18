// perf_model.cpp : cycle-approximate performance model of the core.
//
//   Trace driven. The C reference model (rv32i_iss.c) executes the program and
//   gives the correct-path instruction stream. For each instruction the model
//   computes the cycle it leaves IF ("fire"), using the same rules as the RTL:
//
//     present  = cycle its PC first reaches IF (the I-cache lookup starts)
//     ready    = present, or present + 1 + MISS_LAT on an I-cache miss
//     earliest = cycle IF/ID is free (previous fire + 1 + its load-use stall)
//     fire     = max(ready, earliest)
//     load-use = 1 if the previous instruction is a load whose rd this one
//                reads and the two are back to back in the pipe
//     EX       = fire + 2 + load-use;   retire = EX + 2
//     mispredict (next PC guessed wrong) -> next PC presented at EX + 1
//
//   The predictor and cache are the same structures as rtl/bpred.v and
//   rtl/icache.v. Predictor updates are applied in the cycle after EX, as in
//   the RTL, so a lookup can miss an update that is still in flight.
//
//   What it leaves out (why it is "approximate", see README):
//     - wrong-path fetches: in the RTL they can start I-cache refills that
//       pollute the cache and block the correct-path fetch until they finish
//     - so its I-cache counters only cover correct-path fetches
//   With no cache it should match the RTL cycle for cycle (make regress checks
//   this on ic0_bp0).
//
//   Usage: perf_model prog.hex [--ic-bytes N] [--line-words N] [--miss-lat N]
//                              [--bp 0|1] [--bht N] [--btb N]
//          --ic-bytes 0 = no cache (ideal fetch). Prints one "MODEL k=v ..." line.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <string>
#include <vector>

extern "C" {
void rm_reset(int iwords, int dwords);
void rm_load(int word_addr, int data);
int rm_step(int *pc, int *insn, int *rd_we, int *rd, int *rd_wdata,
            int *mem_we, int *mem_addr, int *mem_wdata);
}

static const int IMEM_WORDS = 512, DMEM_WORDS = 256;   // riscv_core defaults
static const uint32_t HALT = 0x0000006f;

struct Insn {
    uint32_t pc, raw, next;   // next = PC of the next correct-path instruction
    uint32_t op() const { return raw & 0x7f; }
    uint32_t rd() const { return (raw >> 7) & 31; }
    uint32_t rs1() const { return (raw >> 15) & 31; }
    uint32_t rs2() const { return (raw >> 20) & 31; }
    bool is_load() const { return op() == 0x03; }
    bool is_branch() const { return op() == 0x63; }
    bool is_jump() const { return op() == 0x6f || op() == 0x67; }
    // same "really reads" rules as the RTL hazard unit
    bool uses_rs1() const { return !(op() == 0x37 || op() == 0x17 || op() == 0x6f); }
    bool uses_rs2() const { return op() == 0x33 || op() == 0x23 || op() == 0x63; }
};

// Direct-mapped I-cache: tags only, the data never matters for timing.
struct ICache {
    int lines, line_words;
    std::vector<int64_t> tag;   // -1 = invalid
    ICache(int bytes, int lw) : lines(bytes / (4 * lw)), line_words(lw), tag(lines, -1) {}
    bool access(uint32_t pc) {          // returns hit; fills on a miss
        uint32_t line = (pc >> 2) / line_words;
        int idx = line % lines;
        int64_t t = line / lines;
        if (tag[idx] == t) return true;
        tag[idx] = t;
        return false;
    }
};

// BHT (2-bit counters, untagged) + tagged BTB, as rtl/bpred.v.
struct Predictor {
    int bht_n, btb_n;
    std::vector<uint8_t> bht;
    struct Entry { bool v = false, jump = false; uint32_t tag = 0, target = 0; };
    std::vector<Entry> btb;
    Predictor(int h, int b) : bht_n(h), btb_n(b), bht(h, 1), btb(b) {}
    uint32_t predict(uint32_t pc) const {   // predicted next PC
        const Entry &e = btb[(pc >> 2) % btb_n];
        bool hit = e.v && e.tag == (pc >> 2) / btb_n;
        return hit && (e.jump || bht[(pc >> 2) % bht_n] >= 2) ? e.target : pc + 4;
    }
    void update(const Insn &in) {
        bool taken = in.is_jump() || (in.is_branch() && in.next != in.pc + 4);
        uint8_t &c = bht[(in.pc >> 2) % bht_n];
        if (in.is_branch()) c = taken ? (c < 3 ? c + 1 : 3) : (c > 0 ? c - 1 : 0);
        if (taken) btb[(in.pc >> 2) % btb_n] = {true, in.is_jump(), (in.pc >> 2) / btb_n, in.next};
    }
};

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s prog.hex [options]\n", argv[0]); return 2; }
    int ic_bytes = 0, line_words = 4, miss_lat = 10, bp = 0, bht_n = 64, btb_n = 16;
    for (int i = 2; i + 1 < argc; i += 2) {
        int v = atoi(argv[i + 1]);
        if (!strcmp(argv[i], "--ic-bytes")) ic_bytes = v;
        else if (!strcmp(argv[i], "--line-words")) line_words = v;
        else if (!strcmp(argv[i], "--miss-lat")) miss_lat = v;
        else if (!strcmp(argv[i], "--bp")) bp = v;
        else if (!strcmp(argv[i], "--bht")) bht_n = v;
        else if (!strcmp(argv[i], "--btb")) btb_n = v;
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }

    // ---- functional run: correct-path trace ----
    rm_reset(IMEM_WORDS, DMEM_WORDS);
    std::ifstream f(argv[1]);
    int n = 0;
    for (std::string line; std::getline(f, line);)
        if (!line.empty()) rm_load(n++, (int)std::stoul(line, nullptr, 16));
    if (n == 0) { fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }

    std::vector<Insn> trace;
    for (int k = 0; k < 1000000; k++) {
        int pc, insn, a, b, c, d, e, g;
        if (rm_step(&pc, &insn, &a, &b, &c, &d, &e, &g)) { fprintf(stderr, "ISS error at pc %08x\n", pc); return 1; }
        if (!trace.empty()) trace.back().next = (uint32_t)pc;
        trace.push_back({(uint32_t)pc, (uint32_t)insn, (uint32_t)pc});
        if ((uint32_t)insn == HALT) break;
    }
    if (trace.back().raw != HALT) { fprintf(stderr, "no halt within 1M instructions\n"); return 1; }

    // ---- timing ----
    ICache ic(ic_bytes ? ic_bytes : 4 * line_words, line_words);
    Predictor pred(bht_n, btb_n);
    std::deque<std::pair<int64_t, Insn>> pending;   // predictor updates: (EX cycle, insn)

    int64_t present = 0, earliest = 0, prev_fire = -10, prev_lu = 0, last_retire = 0;
    long ic_miss = 0, branches = 0, jumps = 0, mispred = 0, lu_stalls = 0;
    const Insn *prev = nullptr;
    for (const Insn &in : trace) {
        int64_t ready = present;
        if (ic_bytes && !ic.access(in.pc)) { ready += 1 + miss_lat; ic_miss++; }
        int64_t fire = std::max(ready, earliest);

        bool lu = prev && prev->is_load() && prev->rd() != 0 && fire == prev_fire + 1 + prev_lu &&
                  ((in.uses_rs1() && in.rs1() == prev->rd()) || (in.uses_rs2() && in.rs2() == prev->rd()));
        int64_t ex = fire + 2 + lu;

        // predict at fire time, seeing only updates written by then
        while (!pending.empty() && pending.front().first < fire) {
            pred.update(pending.front().second);
            pending.pop_front();
        }
        uint32_t guess = bp ? pred.predict(in.pc) : in.pc + 4;
        bool miss = guess != in.next;
        if (in.is_branch() || in.is_jump()) pending.push_back({ex, in});

        branches += in.is_branch();
        jumps += in.is_jump();
        mispred += miss;
        lu_stalls += lu;
        last_retire = ex + 2;

        present = miss ? ex + 1 : fire + 1;
        earliest = miss ? ex + 1 : fire + 1 + lu;
        prev = &in; prev_fire = fire; prev_lu = lu;
    }

    long cycles = (long)last_retire + 1, instret = (long)trace.size();
    printf("MODEL cycles=%ld instret=%ld ipc=%.4f ic_access=%ld ic_miss=%ld branches=%ld jumps=%ld "
           "mispredicts=%ld lu_stalls=%ld\n",
           cycles, instret, (double)instret / cycles, instret, ic_bytes ? ic_miss : 0, branches, jumps,
           mispred, lu_stalls);
    return 0;
}
