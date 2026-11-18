#!/usr/bin/env python3
"""Correctness regression: every program on every config, one at a time.

Programs: directed tests, the benchmarks, and random programs from
tools/rvgen.py (rand_mix / rand_branch / rand_mem, wrapped in a 3-pass loop so
the predictor sees branches more than once). Each run passes only if every
retired instruction matched the C reference model, no SVA fired, and the
perf counters add up (see tb/tb_main.cpp).

Extra check: on ic0_bp0 (no cache, no predictor) the C++ performance model
must predict the exact RTL cycle count, because nothing it leaves out
(wrong-path fetch, cache refills, predictor update timing) exists there.

Writes <out>/summary.md and <out>/<cfg>/<test>.log. Exit code 1 on any failure.
"""
import argparse, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAND_TESTS = ["rand_mix", "rand_branch", "rand_mem"]


def run(cmd):
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def kv(line):
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}


def model_cmd(cfg, hexfile, miss_lat):
    ic, bp = re.match(r"ic(\d+)_bp(\d)", cfg).groups()
    return ["build/perf_model", hexfile, "--ic-bytes", ic, "--miss-lat", str(miss_lat), "--bp", bp]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cfgs", nargs="+", required=True)
    ap.add_argument("--tests", nargs="+", required=True, help="names of build/progs/<name>.hex")
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--miss-lat", type=int, default=10)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = os.path.join(ROOT, a.out)

    progs = [(t, f"build/progs/{t}.hex") for t in a.tests]
    for t in RAND_TESTS:
        for s in range(1, a.seeds + 1):
            d = os.path.join(a.out, "runs", f"{t}_s{s}")
            os.makedirs(os.path.join(ROOT, d), exist_ok=True)
            rc, log = run([sys.executable, "tools/rvgen.py", "--test", t, "--seed", str(s),
                           "--loops", "3", "--out", f"{d}/program.asm"])
            if rc:
                sys.exit(f"rvgen failed: {log}")
            progs.append((f"{t}_s{s}", f"{d}/program.hex"))

    rows, fails, covers = [], [], {}
    for cfg in a.cfgs:
        os.makedirs(os.path.join(out, cfg), exist_ok=True)
        npass = retired = 0
        for name, hexfile in progs:
            rc, log = run([f"build/{cfg}/Vcore", hexfile])
            ok = rc == 0 and "RESULT PASS" in log
            m = re.search(r"^PERF .*$", log, re.M)
            perf = kv(m.group(0)) if m else {}
            c = re.search(r"^COVER .*$", log, re.M)
            for k, v in (kv(c.group(0)) if c else {}).items():
                covers[k] = covers.get(k, 0) + v
            if ok and cfg == "ic0_bp0":
                mrc, mlog = run(model_cmd(cfg, hexfile, a.miss_lat))
                mc = kv(mlog).get("cycles")
                if mrc or mc != perf.get("cycles"):
                    ok = False
                    log += f"\nMODEL CHECK FAIL: model cycles={mc}, rtl cycles={perf.get('cycles')}\n{mlog}"
            open(os.path.join(out, cfg, f"{name}.log"), "w").write(log)
            if ok:
                npass += 1
                retired += perf.get("instret", 0)
            else:
                first = next((l for l in log.splitlines() if "FAIL" in l or "Error" in l), "no RESULT line")
                fails.append(f"{cfg} {name}: {first}")
        rows.append((cfg, len(progs), npass, retired))
        print(f"{cfg:10s} {npass}/{len(progs)} passed, {retired} instructions checked", flush=True)

    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write("| Config | Runs | Pass | Retired instructions checked |\n|---|---|---|---|\n")
        for cfg, n, p, r in rows:
            f.write(f"| {cfg} | {n} | {p} | {r} |\n")
        f.write("\nCover points (summed over all runs): " +
                ", ".join(f"{k}={v}" for k, v in sorted(covers.items())) + "\n")
        if fails:
            f.write("\nFailures:\n" + "".join(f"- {x}\n" for x in fails))
    missed = [k for k, v in covers.items() if v == 0]
    print("covers:", ", ".join(f"{k}={v}" for k, v in sorted(covers.items())))
    for x in fails:
        print("FAIL", x)
    if missed:
        print("cover points never hit:", ", ".join(missed))
    total = sum(r[1] for r in rows)
    print(f"REGRESSION {'PASS' if not fails and not missed else 'FAIL'}: "
          f"{total - len(fails)}/{total} runs passed")
    sys.exit(1 if fails or missed else 0)


if __name__ == "__main__":
    main()
