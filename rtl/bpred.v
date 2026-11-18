// -----------------------------------------------------------------------------
// bpred.v : branch predictor = 2-bit saturating-counter BHT + small BTB.
//
//   Lookup in IF (combinational, on the fetch PC):
//     predict taken  if the BTB has an entry for this PC and
//                    (it is an unconditional jump, or its BHT counter >= 2)
//     target         = the target stored in the BTB entry
//   Update in EX, once per resolved control-flow instruction:
//     - conditional branch: BHT counter +1 if taken, -1 if not (saturating)
//     - any taken branch/jump: write {tag, target, is_jump} into the BTB
//
//   The BHT is indexed by PC bits only (no tag), so two branches can share a
//   counter (aliasing). The BTB is tagged, so a non-branch PC never gets a
//   "taken" prediction. JALR gets the last target seen at that PC.
//
//   EN = 0 gives "always predict not taken", which is exactly the original
//   core (every taken branch or jump redirects from EX).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module bpred #(
    parameter integer EN          = 1,
    parameter integer BHT_ENTRIES = 64,   // power of 2, >= 2
    parameter integer BTB_ENTRIES = 16    // power of 2, >= 2
) (
    input  wire        clk,
    input  wire        rst_n,
    // IF: lookup
    input  wire [31:0] if_pc,
    output wire        pred_taken,
    output wire [31:0] pred_target,
    // EX: update
    input  wire        upd_valid,     // a branch or jump is resolving in EX
    input  wire        upd_is_jump,   // JAL/JALR (always taken)
    input  wire        upd_taken,
    input  wire [31:0] upd_pc,
    input  wire [31:0] upd_target
);
    generate
    if (EN == 0) begin : g_off
        assign pred_taken  = 1'b0;
        assign pred_target = 32'd0;
        wire _unused = &{1'b0, clk, rst_n, if_pc, upd_valid, upd_is_jump,
                         upd_taken, upd_pc, upd_target};
    end else begin : g_on
        localparam integer HW = $clog2(BHT_ENTRIES);
        localparam integer BW = $clog2(BTB_ENTRIES);
        localparam integer TW = 30 - BW;

        reg [1:0]    bht     [0:BHT_ENTRIES-1];  // 00,01 = not taken; 10,11 = taken
        reg          btb_v   [0:BTB_ENTRIES-1];
        reg [TW-1:0] btb_tag [0:BTB_ENTRIES-1];
        reg [31:0]   btb_tgt [0:BTB_ENTRIES-1];
        reg          btb_jmp [0:BTB_ENTRIES-1];

        // ---- lookup ----
        wire [HW-1:0] l_h = if_pc[2 +: HW];
        wire [BW-1:0] l_b = if_pc[2 +: BW];
        wire btb_hit = btb_v[l_b] && (btb_tag[l_b] == if_pc[31 -: TW]);
        assign pred_taken  = btb_hit && (btb_jmp[l_b] || bht[l_h][1]);
        assign pred_target = btb_tgt[l_b];

        // ---- update ----
        wire [HW-1:0] u_h = upd_pc[2 +: HW];
        wire [BW-1:0] u_b = upd_pc[2 +: BW];
        wire [1:0]    ctr = bht[u_h];

        integer k;
        always @(posedge clk) begin
            if (!rst_n) begin
                for (k = 0; k < BHT_ENTRIES; k = k + 1) bht[k] <= 2'b01;  // weakly not taken
                for (k = 0; k < BTB_ENTRIES; k = k + 1) btb_v[k] <= 1'b0;
            end else if (upd_valid) begin
                if (!upd_is_jump) begin
                    if (upd_taken && ctr != 2'b11)       bht[u_h] <= ctr + 2'b01;
                    else if (!upd_taken && ctr != 2'b00) bht[u_h] <= ctr - 2'b01;
                end
                if (upd_taken) begin
                    btb_v[u_b]   <= 1'b1;
                    btb_tag[u_b] <= upd_pc[31 -: TW];
                    btb_tgt[u_b] <= upd_target;
                    btb_jmp[u_b] <= upd_is_jump;
                end
            end
        end

        wire _unused = &{1'b0, if_pc[1:0], upd_pc[1:0], bht[l_h][0]};
    end
    endgenerate

endmodule

`default_nettype wire
