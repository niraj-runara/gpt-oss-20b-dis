#!/usr/bin/env python3
"""Plot unified vs disaggregated benchmark comparison from combined_results.json."""
import argparse
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from cost_model import cost_per_million_tokens


def load(path):
    with open(path) as f:
        data = json.load(f)
    df = pd.DataFrame(data)
    # Recompute from current cost_model (JSON may have stale costs from an older model).
    df["cost_per_1m_tokens_usd"] = df.apply(
        lambda row: cost_per_million_tokens(row["deployment"], row["tokens_per_sec"]),
        axis=1,
    )
    return df


def plot_metric(df, ycol, ylabel, title, out_path):
    fig, ax = plt.subplots(figsize=(7, 5))
    for label, group in df.groupby("deployment"):
        group = group.sort_values("concurrency")
        ax.plot(group["concurrency"], group[ycol], marker="o", label=label)
    ax.set_xlabel("Concurrent users")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.set_xscale("log", base=2)
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"wrote {out_path}")


def plot_latency_percentiles(df, out_path):
    fig, axes = plt.subplots(1, 3, figsize=(16, 5), sharey=True)
    percentiles = [("latency_p50_s", "p50"), ("latency_p95_s", "p95"), ("latency_p99_s", "p99")]
    for ax, (col, name) in zip(axes, percentiles):
        for label, group in df.groupby("deployment"):
            group = group.sort_values("concurrency")
            ax.plot(group["concurrency"], group[col], marker="o", label=label)
        ax.set_title(f"Latency {name}")
        ax.set_xlabel("Concurrent users")
        ax.set_xscale("log", base=2)
        ax.grid(True, alpha=0.3)
    axes[0].set_ylabel("Latency (s)")
    axes[0].legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"wrote {out_path}")


def print_summary_table(df):
    cols = ["deployment", "concurrency", "tokens_per_sec", "latency_p50_s", "latency_p95_s",
            "latency_p99_s", "cost_per_1m_tokens_usd", "num_errors"]
    print(df[cols].sort_values(["deployment", "concurrency"]).to_string(index=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", default=os.path.join(os.path.dirname(__file__), "results", "combined_results.json"))
    parser.add_argument("--out-dir", default=os.path.join(os.path.dirname(__file__), "results", "plots"))
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    df = load(args.results)

    print_summary_table(df)

    plot_metric(df, "tokens_per_sec", "Tokens / sec", "Throughput: Unified vs Disaggregated",
                os.path.join(args.out_dir, "throughput.png"))
    plot_latency_percentiles(df, os.path.join(args.out_dir, "latency_percentiles.png"))
    plot_metric(df, "cost_per_1m_tokens_usd", "USD per 1M tokens", "Cost per 1M tokens: Unified vs Disaggregated",
                os.path.join(args.out_dir, "cost_per_1m_tokens.png"))


if __name__ == "__main__":
    main()
