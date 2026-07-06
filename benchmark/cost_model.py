#!/usr/bin/env python3
"""GCP cost model for the unified vs disaggregated deployments.

*** These hourly prices are approximate on-demand list prices and WILL drift.
*** Verify current numbers at https://cloud.google.com/compute/all-pricing
*** (or your actual billing/committed-use/spot rates) before trusting the
*** cost-per-1M-tokens numbers this produces for any real decision.
"""

HOURLY_COST_USD = {
    # 8 vCPU / 32 GB, no GPU — runs nginx/router/kv_broker/cache_server.
    "n2-standard-8": 0.3888,
    # 16 vCPU / 64 GB + 1x NVIDIA L4 (bundled g2 pricing), us-central1 on-demand.
    "g2-standard-16": 1.0,
    # 24 vCPU / 96 GB + 2x NVIDIA L4 (bundled g2 pricing), us-central1 on-demand.
    "g2-standard-24": 1.94,
}

DEPLOYMENT_INSTANCES = {
    "unified": {
        "unified-node": "g2-standard-16",
    },
    "disaggregated": {
        "cpu-node": "n2-standard-8",
        "prefill-node": "g2-standard-24",
        "decode-node": "g2-standard-24",
    },
}


def hourly_cost(deployment: str) -> float:
    instances = DEPLOYMENT_INSTANCES[deployment]
    return sum(HOURLY_COST_USD[machine_type] for machine_type in instances.values())


def cost_per_million_tokens(deployment: str, tokens_per_sec: float) -> float:
    if tokens_per_sec <= 0:
        return float("inf")
    tokens_per_hour = tokens_per_sec * 3600
    cost_per_hour = hourly_cost(deployment)
    cost_per_token = cost_per_hour / tokens_per_hour
    return cost_per_token * 1_000_000


if __name__ == "__main__":
    for deployment in DEPLOYMENT_INSTANCES:
        print(f"{deployment}: ${hourly_cost(deployment):.4f}/hr across {list(DEPLOYMENT_INSTANCES[deployment])}")
