// -----------------------------------------------------------------------------
// riscv_core.v : 32-bit RV32I 5-stage pipelined processor.
//
//   Stages:  IF -> ID -> EX -> MEM -> WB
//   Hazards: - full EX-stage forwarding from EX/MEM and MEM/WB
//            - one-cycle load-use stall (detected in ID)
//            - branches/jumps resolve in EX; IF/ID and ID/EX are flushed on a
//              mispredict (2-cycle penalty; without BP every taken one is)
//
//   Memories are word-addressed internally; LB/LH/LBU/LHU/SB/SH select byte
//   lanes inside the word. Misaligned accesses are not trapped (low bits ignored).
//
//   Micro-architecture additions (rv32-uarch-perf), each with an off switch:
//     - ICACHE_EN: direct-mapped I-cache in front of a slow instruction memory
//       (rtl/icache.v). IF stalls while a line is refilled.
//     - BP_EN: BHT + BTB branch predictor (rtl/bpred.v). Predict in IF,
//       resolve in EX, flush IF/ID and ID/EX only on a mispredict.
//       BP_EN = 0 is the original "predict not taken" behaviour.
//     - performance counters, read through perf_sel/perf_rdata. Every bubble
//       carries the reason it was created; a bubble reaching WB is counted
//       against that reason, so cycles = instret + sum of bubble counters.
//
//   Verification changes (rv32-emu-verif copy of the core):
//     - the program is written through the imem_we port by the HDL-side load
//       transactor instead of $readmemh, so one compiled model runs any test
//     - a retire trace port (rvfi-style) reports every instruction that leaves
//       WB, so the testbench can compare each one with the C reference model
//     - a valid bit travels with each instruction so flushed bubbles never retire
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
`include "riscv_defs.vh"

module riscv_core #(
    parameter integer IMEM_WORDS    = 512,
    parameter integer DMEM_WORDS    = 256,
    parameter integer ICACHE_EN     = 1,
    parameter integer IC_LINES      = 8,
    parameter integer IC_LINE_WORDS = 4,
    parameter integer IC_MISS_LAT   = 10,
    parameter integer BP_EN         = 1,
    parameter integer BHT_ENTRIES   = 64,
    parameter integer BTB_ENTRIES   = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    // program load port (word address), used while the core is held in reset
    input  wire        imem_we,
    input  wire [31:0] imem_waddr,
    input  wire [31:0] imem_wdata,
    // retire trace: one pulse per instruction leaving WB, in program order
    output wire        rvfi_valid,
    output wire [31:0] rvfi_pc,
    output wire [31:0] rvfi_insn,
    output wire        rvfi_rd_we,     // register write happened (rd != x0)
    output wire [4:0]  rvfi_rd,
    output wire [31:0] rvfi_rd_wdata,
    output wire        rvfi_mem_we,    // store retired
    output wire [31:0] rvfi_mem_addr,
    output wire [31:0] rvfi_mem_wdata, // whole memory word after the store
    // performance counters (see PERF_* below)
    input  wire [3:0]  perf_sel,
    output reg  [31:0] perf_rdata
);
    // Bubble causes. Reset bubbles are FILL; the others say which hazard made them.
    localparam [1:0] C_FILL = 2'd0, C_IC = 2'd1, C_LU = 2'd2, C_BR = 2'd3;

    // =====================================================================
    // IF stage
    // =====================================================================
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;

    // Redirect and stall controls (driven from later stages, below).
    wire        redirect;       // EX found a mispredict
    wire [31:0] redirect_pc;
    wire        lu_stall;       // load-use bubble
    wire        ic_ready;       // instruction available this cycle

    wire [31:0] if_instr;
    wire        ic_miss_start, ic_busy;

    icache #(
        .EN(ICACHE_EN), .LINES(IC_LINES), .LINE_WORDS(IC_LINE_WORDS),
        .MISS_LAT(IC_MISS_LAT), .MEM_WORDS(IMEM_WORDS)
    ) u_icache (
        .clk(clk), .rst_n(rst_n),
        .mem_we(imem_we), .mem_waddr(imem_waddr), .mem_wdata(imem_wdata),
        .pc(pc), .fill_ok(!redirect), .ready(ic_ready), .instr(if_instr),
        .miss_start(ic_miss_start), .busy(ic_busy)
    );

    // EX-side update signals for the predictor (declared below).
    wire        bp_upd_valid, bp_upd_jump, bp_upd_taken;
    wire [31:0] bp_upd_pc, bp_upd_target;
    wire        if_pred_taken;
    wire [31:0] if_pred_target;

    bpred #(.EN(BP_EN), .BHT_ENTRIES(BHT_ENTRIES), .BTB_ENTRIES(BTB_ENTRIES)) u_bpred (
        .clk(clk), .rst_n(rst_n),
        .if_pc(pc), .pred_taken(if_pred_taken), .pred_target(if_pred_target),
        .upd_valid(bp_upd_valid), .upd_is_jump(bp_upd_jump), .upd_taken(bp_upd_taken),
        .upd_pc(bp_upd_pc), .upd_target(bp_upd_target)
    );

    // IF hands an instruction to ID this cycle.
    wire if_fire = ic_ready && !lu_stall && !redirect;

    always @(posedge clk) begin
        if (!rst_n)                     pc <= 32'd0;
        else if (redirect)              pc <= redirect_pc;
        else if (lu_stall || !ic_ready) pc <= pc;          // freeze
        else if (if_pred_taken)         pc <= if_pred_target;
        else                            pc <= pc_plus4;
    end

    // =====================================================================
    // IF/ID pipeline register
    // =====================================================================
    reg [31:0] ifid_pc, ifid_instr, ifid_pred_target;
    reg        ifid_valid, ifid_pred_taken;
    reg [1:0]  ifid_cause;
    always @(posedge clk) begin
        if (!rst_n || redirect || (!lu_stall && !ic_ready)) begin   // bubble
            ifid_pc    <= 32'd0;
            ifid_instr <= 32'd0;
            ifid_valid <= 1'b0;
            ifid_pred_taken  <= 1'b0;
            ifid_pred_target <= 32'd0;
            ifid_cause <= !rst_n ? C_FILL : redirect ? C_BR : C_IC;
        end else if (!lu_stall) begin    // advance (a load-use stall holds)
            ifid_pc    <= pc;
            ifid_instr <= if_instr;
            ifid_valid <= 1'b1;
            ifid_pred_taken  <= if_pred_taken;
            ifid_pred_target <= if_pred_target;
            ifid_cause <= C_FILL;        // don't care for a valid instruction
        end
    end

    // =====================================================================
    // ID stage : decode, register read, immediate
    // =====================================================================
    wire [6:0] opcode = ifid_instr[6:0];
    wire [4:0] rs1    = ifid_instr[19:15];
    wire [4:0] rs2    = ifid_instr[24:20];
    wire [4:0] rd     = ifid_instr[11:7];
    wire [2:0] funct3 = ifid_instr[14:12];
    wire       funct7_5 = ifid_instr[30];

    wire        c_reg_write, c_mem_read, c_mem_write, c_alu_src;
    wire        c_branch, c_jump, c_jalr, c_alu_a_pc;
    wire [1:0]  c_wb_sel;
    wire [3:0]  c_alu_ctrl;

    control_unit u_ctrl (
        .opcode(opcode), .funct3(funct3), .funct7_5(funct7_5),
        .reg_write(c_reg_write), .mem_read(c_mem_read), .mem_write(c_mem_write),
        .alu_src(c_alu_src), .branch(c_branch), .jump(c_jump), .jalr(c_jalr),
        .alu_a_pc(c_alu_a_pc), .wb_sel(c_wb_sel), .alu_ctrl(c_alu_ctrl)
    );

    wire [31:0] rd1, rd2, imm;

    // regfile write signals come from WB stage (declared later)
    wire        wb_reg_write;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    regfile u_rf (
        .clk(clk), .we(wb_reg_write),
        .ra1(rs1), .ra2(rs2), .wa(wb_rd), .wd(wb_data),
        .rd1(rd1), .rd2(rd2)
    );

    imm_gen u_imm (.instr(ifid_instr), .imm(imm));

    // ---- load-use hazard detection ----
    // If the instruction in EX is a load whose rd is a source of the ID
    // instruction, stall one cycle.
    // Only fields the instruction really reads count as sources: in I/U/J
    // formats bits [24:20] (and [19:15] for U/J) are immediate bits, and
    // matching them against rd caused needless stalls (BUGS.md, bug 1).
    wire idex_mem_read;   // from ID/EX (declared below)
    wire [4:0] idex_rd;
    wire uses_rs1 = !(opcode == `OP_LUI || opcode == `OP_AUIPC || opcode == `OP_JAL);
    wire uses_rs2 = (opcode == `OP_RTYPE) || (opcode == `OP_STORE) || (opcode == `OP_BRANCH);
    assign lu_stall = ifid_valid && idex_mem_read && (idex_rd != 5'd0) &&
                   ((uses_rs1 && idex_rd == rs1) || (uses_rs2 && idex_rd == rs2));

    // Bubble injected into ID/EX when stalling or flushing.
    wire id_bubble = lu_stall || redirect;

    // =====================================================================
    // ID/EX pipeline register
    // =====================================================================
    reg        idex_reg_write, idex_mem_read_r, idex_mem_write, idex_alu_src;
    reg        idex_branch, idex_jump, idex_jalr, idex_alu_a_pc;
    reg [1:0]  idex_wb_sel;
    reg [3:0]  idex_alu_ctrl;
    reg [2:0]  idex_funct3;
    reg [31:0] idex_pc, idex_rd1, idex_rd2, idex_imm;
    reg [4:0]  idex_rs1, idex_rs2, idex_rd_r;
    reg        idex_valid;
    reg [31:0] idex_instr;
    reg        idex_pred_taken;
    reg [31:0] idex_pred_target;
    reg [1:0]  idex_cause;

    assign idex_mem_read = idex_mem_read_r;
    assign idex_rd       = idex_rd_r;

    always @(posedge clk) begin
        if (!rst_n || id_bubble) begin
            idex_reg_write <= 1'b0; idex_mem_read_r <= 1'b0; idex_mem_write <= 1'b0;
            idex_alu_src   <= 1'b0; idex_branch     <= 1'b0; idex_jump      <= 1'b0;
            idex_jalr      <= 1'b0; idex_alu_a_pc   <= 1'b0; idex_wb_sel    <= 2'd0;
            idex_alu_ctrl  <= 4'd0; idex_funct3     <= 3'd0;
            idex_pc  <= 32'd0; idex_rd1 <= 32'd0; idex_rd2 <= 32'd0; idex_imm <= 32'd0;
            idex_rs1 <= 5'd0;  idex_rs2 <= 5'd0;  idex_rd_r <= 5'd0;
            idex_valid <= 1'b0; idex_instr <= 32'd0;
            idex_pred_taken <= 1'b0; idex_pred_target <= 32'd0;
            idex_cause <= !rst_n ? C_FILL : redirect ? C_BR : C_LU;
        end else begin
            idex_reg_write <= c_reg_write; idex_mem_read_r <= c_mem_read;
            idex_mem_write <= c_mem_write; idex_alu_src    <= c_alu_src;
            idex_branch    <= c_branch;    idex_jump       <= c_jump;
            idex_jalr      <= c_jalr;      idex_alu_a_pc   <= c_alu_a_pc;
            idex_wb_sel    <= c_wb_sel;    idex_alu_ctrl   <= c_alu_ctrl;
            idex_funct3    <= funct3;
            idex_pc  <= ifid_pc; idex_rd1 <= rd1; idex_rd2 <= rd2; idex_imm <= imm;
            idex_rs1 <= rs1;     idex_rs2 <= rs2; idex_rd_r <= rd;
            idex_valid <= ifid_valid; idex_instr <= ifid_instr;
            idex_pred_taken <= ifid_pred_taken; idex_pred_target <= ifid_pred_target;
            idex_cause <= ifid_cause;
        end
    end

    // =====================================================================
    // EX stage : forwarding, ALU, branch resolution
    // =====================================================================
    // EX/MEM and MEM/WB forwarding sources (declared below).
    wire        exmem_reg_write;
    wire [4:0]  exmem_rd;
    wire [31:0] exmem_alu;

    // forward select: 2'b10 => from EX/MEM, 2'b01 => from MEM/WB, 2'b00 => regfile
    reg [1:0] fwd_a, fwd_b;
    always @(*) begin
        fwd_a = 2'b00;
        if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs1)
            fwd_a = 2'b10;
        else if (wb_reg_write && wb_rd != 5'd0 && wb_rd == idex_rs1)
            fwd_a = 2'b01;

        fwd_b = 2'b00;
        if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs2)
            fwd_b = 2'b10;
        else if (wb_reg_write && wb_rd != 5'd0 && wb_rd == idex_rs2)
            fwd_b = 2'b01;
    end

    reg [31:0] fwd_rs1, fwd_rs2;
    always @(*) begin
        case (fwd_a)
            2'b10:   fwd_rs1 = exmem_alu;
            2'b01:   fwd_rs1 = wb_data;
            default: fwd_rs1 = idex_rd1;
        endcase
        case (fwd_b)
            2'b10:   fwd_rs2 = exmem_alu;
            2'b01:   fwd_rs2 = wb_data;
            default: fwd_rs2 = idex_rd2;
        endcase
    end

    wire [31:0] alu_a = idex_alu_a_pc ? idex_pc  : fwd_rs1;
    wire [31:0] alu_b = idex_alu_src  ? idex_imm : fwd_rs2;

    wire [31:0] alu_y;
    wire        alu_zero;
    alu u_alu (.a(alu_a), .b(alu_b), .ctrl(idex_alu_ctrl), .y(alu_y), .zero(alu_zero));

    // branch comparator (uses forwarded register values)
    reg branch_take;
    always @(*) begin
        case (idex_funct3)
            3'b000:  branch_take = (fwd_rs1 == fwd_rs2);                 // BEQ
            3'b001:  branch_take = (fwd_rs1 != fwd_rs2);                 // BNE
            3'b100:  branch_take = ($signed(fwd_rs1) <  $signed(fwd_rs2)); // BLT
            3'b101:  branch_take = ($signed(fwd_rs1) >= $signed(fwd_rs2)); // BGE
            3'b110:  branch_take = (fwd_rs1 <  fwd_rs2);                 // BLTU
            3'b111:  branch_take = (fwd_rs1 >= fwd_rs2);                 // BGEU
            default: branch_take = 1'b0;
        endcase
    end

    wire branch_taken = idex_branch && branch_take;
    wire ex_taken     = branch_taken || idex_jump;   // actual outcome

    // target: JALR -> (rs1+imm)&~1 ; branch/JAL -> pc+imm
    wire [31:0] ex_target = idex_jalr ? ((fwd_rs1 + idex_imm) & ~32'd1)
                                      : (idex_pc + idex_imm);

    wire [31:0] idex_pc4 = idex_pc + 32'd4;

    // Mispredict = the PC fetched after this instruction was wrong. Compare
    // next PCs, not directions: a taken branch/jump to pc+4 predicted
    // not-taken fetched the right path and must not flush (BUGS.md, bug 1).
    // Checked for every valid instruction, so even a (impossible with a
    // tagged BTB) "taken" guess on a non-branch would be corrected.
    wire [31:0] pred_next  = idex_pred_taken ? idex_pred_target : idex_pc4;
    assign redirect_pc     = ex_taken ? ex_target : idex_pc4;
    assign redirect        = idex_valid && (redirect_pc != pred_next);

    assign bp_upd_valid  = idex_valid && (idex_branch || idex_jump);
    assign bp_upd_jump   = idex_jump;
    assign bp_upd_taken  = ex_taken;
    assign bp_upd_pc     = idex_pc;
    assign bp_upd_target = ex_target;

    // =====================================================================
    // EX/MEM pipeline register
    // =====================================================================
    reg        exmem_reg_write_r, exmem_mem_write;
    reg [1:0]  exmem_cause;
    reg [1:0]  exmem_wb_sel;
    reg [31:0] exmem_alu_r, exmem_store, exmem_pc4;
    reg [4:0]  exmem_rd_r;
    reg [2:0]  exmem_funct3;   // load/store width and sign
    reg        exmem_valid;
    reg [31:0] exmem_pc, exmem_instr;

    assign exmem_reg_write = exmem_reg_write_r;
    assign exmem_rd        = exmem_rd_r;
    // Forwarded EX/MEM result. A JAL/JALR writes its link (pc+4), not the
    // ALU output. The original core always flushed behind a jump, so this
    // path was never used; correct prediction exposed it (BUGS.md, bug 2).
    assign exmem_alu       = (exmem_wb_sel == `WB_PC4) ? exmem_pc4 : exmem_alu_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            exmem_reg_write_r <= 1'b0; exmem_mem_write <= 1'b0; exmem_cause <= C_FILL;
            exmem_wb_sel <= 2'd0; exmem_alu_r <= 32'd0; exmem_store <= 32'd0;
            exmem_pc4 <= 32'd0; exmem_rd_r <= 5'd0; exmem_funct3 <= 3'd0;
            exmem_valid <= 1'b0; exmem_pc <= 32'd0; exmem_instr <= 32'd0;
        end else begin
            exmem_reg_write_r <= idex_reg_write;
            exmem_cause       <= idex_cause;
            exmem_mem_write   <= idex_mem_write;
            exmem_wb_sel      <= idex_wb_sel;
            exmem_alu_r       <= alu_y;
            exmem_store       <= fwd_rs2;     // store data (forwarded)
            exmem_pc4         <= idex_pc4;
            exmem_rd_r        <= idex_rd_r;
            exmem_funct3      <= idex_funct3;
            exmem_valid       <= idex_valid;
            exmem_pc          <= idex_pc;
            exmem_instr       <= idex_instr;
        end
    end

    // =====================================================================
    // MEM stage : data memory
    // =====================================================================
    reg  [31:0] dmem [0:DMEM_WORDS-1];
    integer di;
    initial for (di = 0; di < DMEM_WORDS; di = di + 1) dmem[di] = 32'd0;

    localparam integer DW = $clog2(DMEM_WORDS);   // addresses wrap at DMEM_WORDS, like the C model
    wire [31:0] mem_rdata = dmem[exmem_alu_r[DW+1:2]];

    // Sub-word stores: replicate the data across the lanes and merge it with
    // the current word under a byte-enable mask (read-modify-write in one cycle,
    // since the read port is asynchronous). funct3: 0 = SB, 1 = SH, 2 = SW.
    wire [1:0]  st_off  = exmem_alu_r[1:0];
    wire [3:0]  st_be   = (exmem_funct3[1:0] == 2'd0) ? (4'b0001 << st_off) :
                          (exmem_funct3[1:0] == 2'd1) ? (st_off[1] ? 4'b1100 : 4'b0011) :
                                                        4'b1111;
    wire [31:0] st_data = (exmem_funct3[1:0] == 2'd0) ? {4{exmem_store[7:0]}} :
                          (exmem_funct3[1:0] == 2'd1) ? {2{exmem_store[15:0]}} :
                                                        exmem_store;
    wire [31:0] st_word = {st_be[3] ? st_data[31:24] : mem_rdata[31:24],
                           st_be[2] ? st_data[23:16] : mem_rdata[23:16],
                           st_be[1] ? st_data[15:8]  : mem_rdata[15:8],
                           st_be[0] ? st_data[7:0]   : mem_rdata[7:0]};

    always @(posedge clk) begin
        if (exmem_mem_write)
            dmem[exmem_alu_r[DW+1:2]] <= st_word;
    end

    // =====================================================================
    // MEM/WB pipeline register
    // =====================================================================
    reg        memwb_reg_write;
    reg [1:0]  memwb_wb_sel;
    reg [31:0] memwb_alu, memwb_mem, memwb_pc4;
    reg [4:0]  memwb_rd;
    reg [2:0]  memwb_funct3;
    reg        memwb_valid, memwb_mem_write;
    reg [31:0] memwb_pc, memwb_instr, memwb_store;
    reg [1:0]  memwb_cause;

    always @(posedge clk) begin
        if (!rst_n) begin
            memwb_reg_write <= 1'b0; memwb_wb_sel <= 2'd0;
            memwb_alu <= 32'd0; memwb_mem <= 32'd0; memwb_pc4 <= 32'd0; memwb_rd <= 5'd0;
            memwb_valid <= 1'b0; memwb_mem_write <= 1'b0; memwb_funct3 <= 3'd0;
            memwb_pc <= 32'd0; memwb_instr <= 32'd0; memwb_store <= 32'd0;
            memwb_cause <= C_FILL;
        end else begin
            memwb_reg_write <= exmem_reg_write_r;
            memwb_wb_sel    <= exmem_wb_sel;
            memwb_alu       <= exmem_alu_r;
            memwb_mem       <= mem_rdata;
            memwb_pc4       <= exmem_pc4;
            memwb_rd        <= exmem_rd_r;
            memwb_valid     <= exmem_valid;
            memwb_mem_write <= exmem_mem_write;
            memwb_pc        <= exmem_pc;
            memwb_instr     <= exmem_instr;
            memwb_store     <= st_word;       // the full word written, for the trace
            memwb_funct3    <= exmem_funct3;
            memwb_cause     <= exmem_cause;
        end
    end

    // =====================================================================
    // WB stage
    // =====================================================================
    // Sub-word loads: shift the addressed lane down, then sign/zero extend.
    // funct3: 0 = LB, 1 = LH, 2 = LW, 4 = LBU, 5 = LHU.
    wire [31:0] ld_lane = memwb_mem >> {memwb_alu[1:0], 3'b000};
    reg  [31:0] load_data;
    always @(*) begin
        case (memwb_funct3)
            3'b000:  load_data = {{24{ld_lane[7]}},  ld_lane[7:0]};
            3'b001:  load_data = {{16{ld_lane[15]}}, ld_lane[15:0]};
            3'b100:  load_data = {24'd0, ld_lane[7:0]};
            3'b101:  load_data = {16'd0, ld_lane[15:0]};
            default: load_data = memwb_mem;
        endcase
    end

    reg [31:0] wb_mux;
    always @(*) begin
        case (memwb_wb_sel)
            `WB_MEM: wb_mux = load_data;
            `WB_PC4: wb_mux = memwb_pc4;
            default: wb_mux = memwb_alu;
        endcase
    end

    assign wb_reg_write = memwb_reg_write;
    assign wb_rd        = memwb_rd;
    assign wb_data      = wb_mux;

    // =====================================================================
    // Retire trace (verification only; no effect on the datapath)
    // =====================================================================
    assign rvfi_valid     = memwb_valid;
    assign rvfi_pc        = memwb_pc;
    assign rvfi_insn      = memwb_instr;
    assign rvfi_rd_we     = memwb_valid && memwb_reg_write && (memwb_rd != 5'd0);
    assign rvfi_rd        = memwb_rd;
    assign rvfi_rd_wdata  = wb_mux;
    assign rvfi_mem_we    = memwb_valid && memwb_mem_write;
    assign rvfi_mem_addr  = memwb_alu;
    assign rvfi_mem_wdata = memwb_store;

    // =====================================================================
    // Performance counters
    // =====================================================================
    // Bubble counters are charged when the bubble reaches WB, using the
    // cause it was tagged with. A cycle either retires an instruction or
    // holds one bubble in WB, so cycles == instret + sum(bub_*) exactly
    // (the testbench checks this). This is a CPI stack built in hardware.
    localparam [3:0] PERF_CYCLES = 4'd0,  PERF_INSTRET = 4'd1, PERF_IC_ACCESS = 4'd2,
                     PERF_IC_MISS = 4'd3, PERF_BRANCH  = 4'd4, PERF_JUMP      = 4'd5,
                     PERF_MISPRED = 4'd6, PERF_BUB_FILL = 4'd7, PERF_BUB_IC   = 4'd8,
                     PERF_BUB_LU  = 4'd9, PERF_BUB_BR  = 4'd10;
    reg [31:0] cnt [0:10];
    integer ci;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (ci = 0; ci <= 10; ci = ci + 1) cnt[ci] <= 32'd0;
        end else begin
            cnt[PERF_CYCLES] <= cnt[PERF_CYCLES] + 32'd1;
            if (memwb_valid)                cnt[PERF_INSTRET]  <= cnt[PERF_INSTRET] + 32'd1;
            else case (memwb_cause)
                C_FILL:  cnt[PERF_BUB_FILL] <= cnt[PERF_BUB_FILL] + 32'd1;
                C_IC:    cnt[PERF_BUB_IC]   <= cnt[PERF_BUB_IC]   + 32'd1;
                C_LU:    cnt[PERF_BUB_LU]   <= cnt[PERF_BUB_LU]   + 32'd1;
                default: cnt[PERF_BUB_BR]   <= cnt[PERF_BUB_BR]   + 32'd1;
            endcase
            // accesses = instructions handed to ID, wrong path included
            if (if_fire)                    cnt[PERF_IC_ACCESS] <= cnt[PERF_IC_ACCESS] + 32'd1;
            if (ic_miss_start)              cnt[PERF_IC_MISS]   <= cnt[PERF_IC_MISS] + 32'd1;
            if (idex_valid && idex_branch)  cnt[PERF_BRANCH]    <= cnt[PERF_BRANCH] + 32'd1;
            if (idex_valid && idex_jump)    cnt[PERF_JUMP]      <= cnt[PERF_JUMP] + 32'd1;
            if (redirect)                   cnt[PERF_MISPRED]   <= cnt[PERF_MISPRED] + 32'd1;
        end
    end

    always @(*) perf_rdata = (perf_sel <= 4'd10) ? cnt[perf_sel] : 32'd0;

    wire _unused = &{1'b0, alu_zero, ld_lane[31:16], exmem_alu_r[31:DW+2], ic_busy};

endmodule

`default_nettype wire
