# rv32-uarch-perf : I-cache + branch predictor on an RV32I 5-stage core,
# a C++ performance model, and an IPC study.
#
#   make sim       one program on one config, with the retire trace
#                  (PROG=bubble_sort CFG=ic128_bp1 by default)
#   make regress   correctness: directed + benchmarks + random, 4 configs
#   make perf      IPC study: 7 benchmarks x 10 configs, RTL vs C++ model
#   make model     build the C++ model and run it on every benchmark
#   make lint      verilator --lint-only -Wall on three parameter sets
#   make clean
#
# A config name is ic<bytes>_bp<0|1>: ic0 = no cache (original, ideal fetch),
# ic64..ic512 = cache size in bytes, 16-byte lines. MISS_LAT applies to all.
#
# Low CPU load by default: one compile job, background priority on macOS.
# COOL=60 sleeps between Verilator builds (laptop thermal limit).

VERILATOR ?= verilator
PYTHON    ?= python3
PERL      ?= perl
CXX       ?= c++
MISS_LAT  ?= 10
COOL      ?= 0
PROG      ?= bubble_sort
CFG       ?= ic128_bp1
SEEDS     ?= 5

ifeq ($(shell uname),Darwin)
NICE ?= taskpolicy -b nice -n 19
else
NICE ?= nice -n 19
endif

RTL   := rtl/alu.v rtl/regfile.v rtl/imm_gen.v rtl/control_unit.v rtl/icache.v rtl/bpred.v rtl/riscv_core.v
SVA   := sva/core_sva.sv
ISS   := model/rv32i_iss.c
MODEL := build/perf_model

REG_CFGS  := ic0_bp0 ic0_bp1 ic64_bp0 ic64_bp1
PERF_CFGS := ic0_bp0 ic0_bp1 ic64_bp0 ic64_bp1 ic128_bp0 ic128_bp1 ic256_bp0 ic256_bp1 ic512_bp0 ic512_bp1
BENCH     := $(basename $(notdir $(wildcard bench/*.asm)))
DIRECTED  := $(basename $(notdir $(wildcard tests/directed/*.asm)))

# ic<bytes>_bp<n> -> Verilog parameters (16-byte lines = 4 words)
ic_bytes = $(patsubst ic%,%,$(word 1,$(subst _, ,$1)))
bp_en    = $(patsubst bp%,%,$(word 2,$(subst _, ,$1)))
lines_0 := 4
lines_64 := 4
lines_128 := 8
lines_256 := 16
lines_512 := 32
params = -GICACHE_EN=$(if $(filter 0,$(call ic_bytes,$1)),0,1) -GIC_LINES=$(lines_$(call ic_bytes,$1)) \
         -GIC_LINE_WORDS=4 -GIC_MISS_LAT=$(MISS_LAT) -GBP_EN=$(call bp_en,$1)

VFLAGS := --cc --exe --build --assert -j 1 --build-jobs 1 -Wno-fatal -Wno-lint -Wno-style \
          -Irtl --top-module riscv_core -MAKEFLAGS OPT_FAST=-O1 -MAKEFLAGS OPT_SLOW=-O0

.PHONY: sim regress perf model lint clean progs
.SECONDARY:

build/%/Vcore: $(RTL) $(SVA) tb/tb_main.cpp $(ISS)
	@mkdir -p build/$*
	$(NICE) $(VERILATOR) $(VFLAGS) $(call params,$*) $(RTL) $(SVA) tb/tb_main.cpp $(CURDIR)/$(ISS) \
	    -Mdir build/$* -o Vcore > build/$*/build.log 2>&1 || (tail -30 build/$*/build.log; false)
	@if [ "$(COOL)" != 0 ]; then echo "cooling $(COOL)s"; sleep $(COOL); fi

$(MODEL): model/perf_model.cpp $(ISS)
	@mkdir -p build
	$(NICE) $(CXX) -std=c++17 -O1 -Wall -Wextra -o $@ model/perf_model.cpp -x c++ $(ISS)

build/progs/%.hex: bench/%.asm tools/assemble.py
	@mkdir -p build/progs
	$(PYTHON) tools/assemble.py $< $@ > /dev/null
build/progs/%.hex: tests/directed/%.asm tools/assemble.py
	@mkdir -p build/progs
	$(PYTHON) tools/assemble.py $< $@ > /dev/null

progs: $(addprefix build/progs/,$(addsuffix .hex,$(BENCH) $(DIRECTED)))

sim: build/$(CFG)/Vcore build/progs/$(PROG).hex
	$(NICE) build/$(CFG)/Vcore build/progs/$(PROG).hex +trace

regress: $(addprefix build/,$(addsuffix /Vcore,$(REG_CFGS))) $(MODEL) progs
	$(NICE) $(PYTHON) scripts/regress.py --cfgs $(REG_CFGS) --tests $(DIRECTED) $(BENCH) \
	    --seeds $(SEEDS) --miss-lat $(MISS_LAT) --out results/regress

perf: $(addprefix build/,$(addsuffix /Vcore,$(PERF_CFGS))) $(MODEL) progs
	$(NICE) $(PYTHON) scripts/perf_study.py --cfgs $(PERF_CFGS) --bench $(BENCH) \
	    --miss-lat $(MISS_LAT) --out results/perf
	$(PERL) scripts/perf_report.pl results/perf > results/perf/summary.md
	@cat results/perf/summary.md

model: $(MODEL) progs
	@for b in $(BENCH); do printf "%-14s " $$b; $(NICE) $(MODEL) build/progs/$$b.hex \
	    --ic-bytes 128 --miss-lat $(MISS_LAT) --bp 1; done

lint:
	$(NICE) $(VERILATOR) --lint-only -Wall -Irtl --top-module riscv_core $(RTL)
	$(NICE) $(VERILATOR) --lint-only -Wall -Irtl --top-module riscv_core -GICACHE_EN=0 -GBP_EN=0 $(RTL)
	$(NICE) $(VERILATOR) --lint-only -Wall -Irtl --top-module riscv_core \
	    -GIC_LINES=2 -GIC_LINE_WORDS=2 -GIC_MISS_LAT=1 -GBHT_ENTRIES=2 -GBTB_ENTRIES=2 $(RTL)
	@echo "lint clean"

clean:
	rm -rf build results
