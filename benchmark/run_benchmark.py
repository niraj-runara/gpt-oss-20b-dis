#!/usr/bin/env python3
"""Sweep concurrency levels against the unified and disaggregated endpoints.

Runs load_test.py once per (deployment, concurrency) pair, tags each result
with its deployment and cost/1M tokens, and writes results/combined_results.json
for plot_results.py to consume.
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from cost_model import cost_per_million_tokens

CONCURRENCY_LEVELS = [1, 5, 10, 20, 40, 80]


def run_one(endpoint, label, concurrency, requests_per_worker, input_tokens, output_tokens, out_dir):
    out_file = os.path.join(out_dir, f"{label}_c{concurrency}.json")
    cmd = [
        sys.executable, os.path.join(os.path.dirname(__file__), "load_test.py"),
        "--endpoint", endpoint,
        "--concurrency", str(concurrency),
        "--requests-per-worker", str(requests_per_worker),
        "--input-tokens", str(input_tokens),
        "--output-tokens", str(output_tokens),
        "--output-file", out_file,
    ]
    print(f"[{label}] concurrency={concurrency} ...", file=sys.stderr)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    with open(out_file) as f:
        return json.load(f)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unified-endpoint", required=True, help="e.g. http://<unified-node-ip>")
    parser.add_argument("--disaggregated-endpoint", required=True, help="e.g. http://<cpu-node-ip>")
    parser.add_argument("--requests-per-worker", type=int, default=5)
    parser.add_argument("--input-tokens", type=int, default=256)
    parser.add_argument("--output-tokens", type=int, default=256)
    parser.add_argument("--out-dir", default=os.path.join(os.path.dirname(__file__), "results"))
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    all_results = []
    for concurrency in CONCURRENCY_LEVELS:
        for label, endpoint, deployment in [
            ("unified", args.unified_endpoint, "unified"),
            ("disaggregated", args.disaggregated_endpoint, "disaggregated"),
        ]:
            summary = run_one(endpoint, label, concurrency, args.requests_per_worker,
                               args.input_tokens, args.output_tokens, args.out_dir)
            summary["deployment"] = label
            summary["cost_per_1m_tokens_usd"] = cost_per_million_tokens(deployment, summary["tokens_per_sec"])
            all_results.append(summary)
            print(f"  -> {summary['tokens_per_sec']:.1f} tok/s, "
                  f"p50={summary['latency_p50_s']:.2f}s p95={summary['latency_p95_s']:.2f}s "
                  f"p99={summary['latency_p99_s']:.2f}s, "
                  f"${summary['cost_per_1m_tokens_usd']:.2f}/1M tok, "
                  f"errors={summary['num_errors']}", file=sys.stderr)

    combined_path = os.path.join(args.out_dir, "combined_results.json")
    with open(combined_path, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"Wrote {combined_path}")


if __name__ == "__main__":
    main()
