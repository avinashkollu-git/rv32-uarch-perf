#!/usr/bin/env python3
"""IPC study: run every benchmark on every config, in RTL and in the C++ model.

For each (config, benchmark) writes <out>/<cfg>/<bench>.log with three parts:
  CONFIG cfg=... ic_bytes=... bp=... miss_lat=...
  the RTL testbench output (PERF ..., RESULT ...)
  the model output (MODEL ...)
scripts/perf_report.pl turns these logs into the summary table.
One run at a time (low CPU load).
"""
import argparse, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(cmd):
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cfgs", nargs="+", required=True)
    ap.add_argument("--bench", nargs="+", required=True)
    ap.add_argument("--miss-lat", type=int, default=10)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    bad = 0
    for cfg in a.cfgs:
        ic, bp = re.match(r"ic(\d+)_bp(\d)$", cfg).groups()
        os.makedirs(os.path.join(ROOT, a.out, cfg), exist_ok=True)
        for b in a.bench:
            hexfile = f"build/progs/{b}.hex"
            rc, rtl = run([f"build/{cfg}/Vcore", hexfile])
            mrc, model = run(["build/perf_model", hexfile, "--ic-bytes", ic,
                              "--miss-lat", str(a.miss_lat), "--bp", bp])
            if rc or mrc or "RESULT PASS" not in rtl:
                bad += 1
                print(f"FAIL {cfg} {b}\n{rtl}{model}")
            with open(os.path.join(ROOT, a.out, cfg, f"{b}.log"), "w") as f:
                f.write(f"CONFIG cfg={cfg} ic_bytes={ic} bp={bp} miss_lat={a.miss_lat}\n{rtl}{model}")
        print(f"{cfg}: {len(a.bench)} benchmarks done", flush=True)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
