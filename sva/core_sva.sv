// core_sva.sv : assertions and cover points for the fetch / predict additions.
//
//   Bound into every riscv_core instance (bind at the bottom), so the RTL has
//   no verification code in it. Built with Verilator --assert; a failure
//   stops the simulation and the run is marked FAIL.
//
//   The flush check is written from the spec ("the next PC was guessed
//   wrong"), not by copying the RTL's redirect equation, so it can disagree
//   with the RTL.
`timescale 1ns / 1ps

module core_sva (
    input logic        clk,
    input logic        rst_n,
    input logic        ic_ready,
    input logic        ic_busy,
    input logic        lu_stall,
    input logic        redirect,
    input logic [31:0] pc,
    input logic        ifid_valid,
    input logic [31:0] ifid_instr,
    input logic        ifid_pred_taken,
    input logic        idex_valid,
    input logic [31:0] idex_pc,
    input logic        idex_jalr,
    input logic        idex_pred_taken,
    input logic [31:0] idex_pred_target,
    input logic        ex_taken,
    input logic [31:0] ex_target
);
    default clocking @(posedge clk); endclocking
    default disable iff (!rst_n);

    // The PC the predictor chose for the instruction after the one in EX,
    // and the PC it really should have been.
    wire [31:0] guessed_next = idex_pred_taken ? idex_pred_target : idex_pc + 32'd4;
    wire [31:0] actual_next  = ex_taken        ? ex_target        : idex_pc + 32'd4;
    wire        real_mispredict = idex_valid && (guessed_next != actual_next);

    // 1. A fetch that misses in the I-cache never enters the pipeline, so it
    //    can never retire: IF/ID gets a bubble (or holds on a load-use stall).
    a_miss_no_issue: assert property (!ic_ready && !lu_stall && !redirect |=> !ifid_valid);

    // 2. While the I-cache is not ready the PC holds, unless EX redirects it.
    a_miss_pc_hold: assert property (!ic_ready && !redirect |=> pc == $past(pc));

    // 3. The pipeline flushes only on a real mispredict ...
    a_flush_only_on_mispredict: assert property (redirect |-> real_mispredict);

    // 4. ... and never misses one.
    a_mispredict_flushes: assert property (real_mispredict |-> redirect);

    // 5. The BTB is tagged, so only branches and jumps are ever predicted taken.
    a_pred_only_ctrl: assert property (ifid_valid && ifid_pred_taken |->
        ifid_instr[6:0] inside {7'b1100011, 7'b1101111, 7'b1100111});

    // Cover points: corner cases the regression should reach. Counted by hand
    // and printed at the end (Verilator's cover property needs a coverage
    // build); scripts/regress.py checks that each one was hit at least once.
    int c_miss_during_lu_stall, c_redirect_during_refill, c_pred_taken_correct, c_jalr_wrong_target;
    always @(posedge clk) if (rst_n) begin
        if (lu_stall && !ic_ready)                                    c_miss_during_lu_stall++;
        if (redirect && ic_busy)                                      c_redirect_during_refill++;
        if (idex_valid && idex_pred_taken && !redirect)               c_pred_taken_correct++;
        if (idex_valid && idex_jalr && idex_pred_taken && redirect)   c_jalr_wrong_target++;
    end
    final $display("COVER miss_during_lu_stall=%0d redirect_during_refill=%0d pred_taken_correct=%0d jalr_wrong_target=%0d",
                   c_miss_during_lu_stall, c_redirect_during_refill, c_pred_taken_correct, c_jalr_wrong_target);
endmodule

bind riscv_core core_sva u_sva (.*);
