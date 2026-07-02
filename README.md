# GPT-OSS-20B FP8 disaggregated inference cluster (GCP)

## Architecture

```
                       ┌─────────────────────────────┐
                       │  cpu-node (n2-standard-8)    │
                       │  nginx :80                   │
                       │  sglang.router :8000         │
                       │  sglang.kv_broker :8200      │
                       │  sglang.cache_server :8100   │
                       └───────────┬─────────┬────────┘
                                   │         │
                     prefill:30000 │         │ decode:30001
                                   ▼         ▼
                 ┌───────────────────┐   ┌───────────────────┐
                 │ prefill-node       │   │ decode-node        │
                 │ g2-standard-16     │   │ g2-standard-16     │
                 │ 1x L4              │   │ 1x L4              │
                 └───────────────────┘   └───────────────────┘

  unified-node (g2-standard-16, 1x L4) — standalone baseline for comparison,
  runs prefill+decode combined on one GPU, not part of the disaggregated set.
```

Model weights: `gs://runara-models-gcp/gpt-oss-20b-fp8/`, synced to local disk
(`/mnt/models/gpt-oss-20b-fp8`) on every GPU node at boot.
Boot image: `runara-base-sglang` (SGLang preinstalled).

GCP project: `luminous-smithy-490001-i9`, zone: `us-central1-a`.

## Boot order

1. `cache_server` (cpu-node)
2. `kv_broker` (cpu-node)
3. prefill worker (prefill-node)
4. decode worker (decode-node)
5. `router` + `nginx` (cpu-node)

Enforced two ways:
- **Self-healing**: every service's systemd unit blocks on `wait_for.sh`
  (TCP/HTTP check) for its dependency before actually launching, and retries
  forever (`StartLimitIntervalSec=0`) on failure. This means any instance can
  reboot independently and the cluster re-converges without manual steps.
- **Explicit control**: [`cluster/orchestrate.sh`](cluster/orchestrate.sh)
  SSHes into each instance in the order above, restarts the relevant service,
  and blocks on its health check before moving to the next — used for first
  bring-up and manual restarts.

## Layout

```
config/cluster.env                        # canonical config values (ports, paths, hostnames)
cluster/startup-scripts/cpu-node-startup.sh
cluster/startup-scripts/prefill-node-startup.sh
cluster/startup-scripts/decode-node-startup.sh
cluster/startup-scripts/unified-node-startup.sh
cluster/orchestrate.sh                    # up | down | status | restart
benchmark/load_test.py                    # async load generator (one endpoint, one concurrency level)
benchmark/cost_model.py                   # GCP hourly pricing -> cost/1M tokens
benchmark/run_benchmark.py                # sweeps concurrency x {unified, disaggregated}
benchmark/plot_results.py                 # throughput / latency / cost plots
```

## *** Verify before running against real infra ***

I don't have access to your GCP project or the `runara-base-sglang` image, so
none of this has been executed against live infrastructure — only syntax
checked. Before first use:

1. **Custom module CLI flags.** `sglang.cache_server`, `sglang.kv_broker`, and
   `sglang.router` are Runara-specific (not upstream SGLang). The flag names
   used here (`--cache-server-url`, `--kv-broker-url`, `--prefill`/`--decode`,
   `--policy`, `--disaggregation-mode`) are best-guess conventions matching
   how `sglang.launch_server`'s real disaggregation flags look upstream. Run
   `python3 -m sglang.<module> --help` on the actual image and fix
   `/opt/runara/bin/run_*.sh` in each startup script if names differ.
2. **Health endpoints.** Workers/router are assumed to expose `GET /health`
   (true for upstream `sglang.launch_server`). `cache_server`/`kv_broker` are
   assumed to *not* have one, so they're checked via plain TCP reachability —
   switch to an HTTP check in `wait_for.sh` calls if they do expose one.
3. **GCP pricing** in `benchmark/cost_model.py` are approximate on-demand list
   prices — update `HOURLY_COST_USD` to match current pricing or your actual
   discounts before trusting cost-per-1M-token numbers.
4. **Internal DNS**: scripts assume all 4 instances share one VPC so GCP's
   automatic internal DNS resolves instances by short name (`cpu-node`,
   `prefill-node`, etc.). If they're in different networks, replace the
   `*_HOST` values in `config/cluster.env` (and every startup script) with
   internal IPs.
5. **`unified-node`** doesn't exist yet per your architecture — create it
   first (see the `gcloud compute instances create` command in the header of
   `unified-node-startup.sh`).

## Deploy

```bash
# Paste/upload each startup script as instance metadata, then reset to run it:
gcloud compute instances add-metadata cpu-node --zone=us-central1-a \
  --metadata-from-file startup-script=cluster/startup-scripts/cpu-node-startup.sh
gcloud compute instances add-metadata prefill-node --zone=us-central1-a \
  --metadata-from-file startup-script=cluster/startup-scripts/prefill-node-startup.sh
gcloud compute instances add-metadata decode-node --zone=us-central1-a \
  --metadata-from-file startup-script=cluster/startup-scripts/decode-node-startup.sh
gcloud compute instances add-metadata unified-node --zone=us-central1-a \
  --metadata-from-file startup-script=cluster/startup-scripts/unified-node-startup.sh

gcloud compute instances reset cpu-node prefill-node decode-node unified-node --zone=us-central1-a

# Once all 4 have booted and self-converged (or to force an ordered first
# bring-up / restart of the disaggregated 3):
./cluster/orchestrate.sh up
./cluster/orchestrate.sh status
```

## Benchmark

```bash
pip install -r benchmark/requirements.txt

python3 benchmark/run_benchmark.py \
  --unified-endpoint http://<unified-node-external-ip> \
  --disaggregated-endpoint http://<cpu-node-external-ip>

python3 benchmark/plot_results.py
```

This sweeps concurrency levels `1, 5, 10, 20, 40, 80` against both endpoints,
records tokens/sec and p50/p95/p99 latency per level, computes cost per 1M
tokens from `benchmark/cost_model.py`, and writes:

- `benchmark/results/combined_results.json` — raw sweep data
- `benchmark/results/plots/throughput.png`
- `benchmark/results/plots/latency_percentiles.png`
- `benchmark/results/plots/cost_per_1m_tokens.png`

`plot_results.py` also prints a summary table to stdout.
