// -----------------------------------------------------------------------------
// icache.v : instruction memory with an optional direct-mapped cache in front.
//
//   EN = 0 : the original behaviour. The instruction memory is read
//            combinationally, so every fetch "hits" in the same cycle.
//   EN = 1 : a direct-mapped cache of LINES lines x LINE_WORDS words.
//            The backing memory takes MISS_LAT cycles to return a whole line.
//
//   Miss timeline (MISS_LAT = L):
//     cycle t      : lookup misses, refill starts      (ready = 0)
//     t+1 .. t+L   : refill in progress (busy)          (ready = 0)
//     end of t+L   : the whole line, tag and valid bit are written
//     t+L+1        : lookup hits                        (ready = 1)
//   so one miss costs L + 1 fetch cycles. The pipeline holds the PC and puts a
//   bubble into IF/ID while ready = 0.
//
//   Simplifications (see README "Limitations"):
//     - blocking: no hit-under-miss, every lookup waits while busy
//     - a refill is never cancelled, even if the PC is redirected meanwhile
//     - the whole line arrives at once (no critical-word-first, no beats)
//
//   Address split for the cache (pc is a byte address, words are 4 bytes):
//     [31 : 2+OW+IW] tag | [2+OW+IW-1 : 2+OW] index | [2+OW-1 : 2] word offset
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module icache #(
    parameter integer EN         = 1,
    parameter integer LINES      = 8,     // power of 2, >= 2
    parameter integer LINE_WORDS = 4,     // power of 2, >= 2
    parameter integer MISS_LAT   = 10,    // >= 1
    parameter integer MEM_WORDS  = 512    // power of 2
) (
    input  wire        clk,
    input  wire        rst_n,
    // program load port into the backing memory (word address)
    input  wire        mem_we,
    input  wire [31:0] mem_waddr,
    input  wire [31:0] mem_wdata,
    // fetch side
    input  wire [31:0] pc,
    input  wire        fill_ok,      // 0: this PC is being replaced by a redirect, don't refill for it
    output wire        ready,        // instr is valid this cycle
    output wire [31:0] instr,
    output wire        miss_start,   // one-cycle pulse per refill (perf counter)
    output wire        busy          // refill in progress (for assertions)
);
    localparam integer MW = $clog2(MEM_WORDS);

    // Backing instruction memory. Addresses wrap at MEM_WORDS, like the C model.
    reg [31:0] mem [0:MEM_WORDS-1];
    integer i;
    initial for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'd0;

    always @(posedge clk)
        if (mem_we) mem[mem_waddr[MW-1:0]] <= mem_wdata;

    wire _unused_waddr = &{1'b0, mem_waddr[31:MW]};

    generate
    if (EN == 0) begin : g_nocache
        assign ready      = 1'b1;
        assign instr      = mem[pc[MW+1:2]];
        assign miss_start = 1'b0;
        assign busy       = 1'b0;
        wire _unused = &{1'b0, pc[31:MW+2], pc[1:0], fill_ok, rst_n};
    end else begin : g_cache
        localparam integer OW = $clog2(LINE_WORDS);
        localparam integer IW = $clog2(LINES);
        localparam integer TW = 30 - OW - IW;
        localparam integer CW = $clog2(MISS_LAT + 1);

        reg [31:0]   data  [0:LINES*LINE_WORDS-1];
        reg [TW-1:0] tag   [0:LINES-1];
        reg [LINES-1:0] valid;

        wire [OW-1:0] off  = pc[2 +: OW];
        wire [IW-1:0] idx  = pc[2+OW +: IW];
        wire [TW-1:0] ptag = pc[31 -: TW];
        wire          hit  = valid[idx] && (tag[idx] == ptag);

        reg          busy_r;
        reg [CW-1:0] cnt;      // cycles left in the refill
        reg [IW-1:0] f_idx;
        reg [TW-1:0] f_tag;

        assign ready      = hit && !busy_r;
        assign instr      = data[{idx, off}];
        assign miss_start = !busy_r && !hit && fill_ok;
        assign busy       = busy_r;

        // word w of the line being filled, in the backing memory (wraps like the C model)
        wire [29:0] f_base = {f_tag, f_idx, {OW{1'b0}}};

        integer w;
        always @(posedge clk) begin
            if (!rst_n) begin
                valid  <= {LINES{1'b0}};
                busy_r <= 1'b0;
                cnt    <= {CW{1'b0}};
            end else if (miss_start) begin
                busy_r <= 1'b1;
                cnt    <= CW'(MISS_LAT - 1);
                f_idx  <= idx;
                f_tag  <= ptag;
            end else if (busy_r) begin
                if (cnt == 0) begin
                    busy_r       <= 1'b0;
                    valid[f_idx] <= 1'b1;
                    tag[f_idx]   <= f_tag;
                    for (w = 0; w < LINE_WORDS; w = w + 1)
                        data[{f_idx, OW'(w)}] <= mem[f_base[MW-1:0] + MW'(w)];
                end else begin
                    cnt <= cnt - 1'b1;
                end
            end
        end

        wire _unused = &{1'b0, pc[1:0], f_base[29:MW]};
    end
    endgenerate

endmodule

`default_nettype wire
