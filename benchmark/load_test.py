#!/usr/bin/env python3
"""Async concurrent load generator against an OpenAI-compatible /v1/completions endpoint.

Simulates N concurrent users, each firing requests back-to-back, and reports
aggregate throughput (tokens/sec) plus p50/p95/p99 end-to-end latency.
"""
import argparse
import asyncio
import json
import statistics
import sys
import time

import aiohttp


def build_prompt(n_tokens: int) -> str:
    # Rough word->token ratio for a filler prompt of approximately n_tokens.
    words = max(1, int(n_tokens / 1.3))
    return " ".join(["hello"] * words)


async def read_response_body(resp):
    text = await resp.text()
    content_type = resp.headers.get("Content-Type", "")
    if "json" in content_type or text.lstrip().startswith(("{", "[")):
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            pass
    return text


async def send_one(session, url, model, prompt, max_tokens, timeout, results, errors):
    payload = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": False,
    }
    start = time.perf_counter()
    try:
        async with session.post(url, json=payload, timeout=timeout) as resp:
            body = await read_response_body(resp)
            end = time.perf_counter()
            if resp.status != 200:
                errors.append(f"HTTP {resp.status}: {str(body)[:200]}")
                return
            if not isinstance(body, dict):
                errors.append(f"HTTP {resp.status}: expected JSON object, got {str(body)[:200]}")
                return
            usage = body.get("usage", {})
            completion_tokens = usage.get("completion_tokens", max_tokens)
            prompt_tokens = usage.get("prompt_tokens", 0)
            results.append({
                "latency_s": end - start,
                "completion_tokens": completion_tokens,
                "prompt_tokens": prompt_tokens,
            })
    except Exception as exc:
        errors.append(str(exc))


async def worker(session, url, model, prompt, max_tokens, timeout, requests_per_worker, results, errors):
    for _ in range(requests_per_worker):
        await send_one(session, url, model, prompt, max_tokens, timeout, results, errors)


async def run_load_test(endpoint, model, concurrency, requests_per_worker, input_tokens, output_tokens, timeout):
    url = endpoint.rstrip("/") + "/v1/completions"
    prompt = build_prompt(input_tokens)
    connector = aiohttp.TCPConnector(limit=0)
    async with aiohttp.ClientSession(connector=connector) as session:
        results, errors = [], []
        wall_start = time.perf_counter()
        tasks = [
            asyncio.create_task(
                worker(session, url, model, prompt, output_tokens, timeout, requests_per_worker, results, errors)
            )
            for _ in range(concurrency)
        ]
        await asyncio.gather(*tasks)
        wall_elapsed = time.perf_counter() - wall_start
    return results, errors, wall_elapsed


def percentile(data, p):
    if not data:
        return 0.0
    data = sorted(data)
    k = (len(data) - 1) * (p / 100)
    f = int(k)
    c = min(f + 1, len(data) - 1)
    if f == c:
        return data[f]
    return data[f] + (data[c] - data[f]) * (k - f)


def summarize(results, errors, wall_elapsed, concurrency):
    latencies = [r["latency_s"] for r in results]
    total_completion_tokens = sum(r["completion_tokens"] for r in results)
    return {
        "concurrency": concurrency,
        "num_requests": len(results) + len(errors),
        "num_success": len(results),
        "num_errors": len(errors),
        "wall_time_s": wall_elapsed,
        "tokens_per_sec": total_completion_tokens / wall_elapsed if wall_elapsed > 0 else 0.0,
        "requests_per_sec": len(results) / wall_elapsed if wall_elapsed > 0 else 0.0,
        "latency_p50_s": percentile(latencies, 50),
        "latency_p95_s": percentile(latencies, 95),
        "latency_p99_s": percentile(latencies, 99),
        "latency_mean_s": statistics.mean(latencies) if latencies else 0.0,
        "errors_sample": errors[:5],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="Base URL, e.g. http://<nginx-ip> or http://<router-ip>:8000")
    parser.add_argument("--model", default="gpt-oss-20b-fp8")
    parser.add_argument("--concurrency", type=int, required=True, help="Number of simulated concurrent users")
    parser.add_argument("--requests-per-worker", type=int, default=5, help="Sequential requests each simulated user sends")
    parser.add_argument("--input-tokens", type=int, default=256)
    parser.add_argument("--output-tokens", type=int, default=256)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--output-file", default=None)
    args = parser.parse_args()

    results, errors, wall_elapsed = asyncio.run(run_load_test(
        args.endpoint, args.model, args.concurrency, args.requests_per_worker,
        args.input_tokens, args.output_tokens, args.timeout,
    ))
    summary = summarize(results, errors, wall_elapsed, args.concurrency)
    print(json.dumps(summary, indent=2))
    if args.output_file:
        with open(args.output_file, "w") as f:
            json.dump(summary, f, indent=2)


if __name__ == "__main__":
    main()
