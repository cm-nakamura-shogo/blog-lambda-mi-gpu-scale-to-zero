"""Lambda handler that serves an LLM with vLLM and reports cold start and generation timings."""

import time

# モジュールの読み込みが始まった時刻。ここから下が Lambda の初期化(INIT)にあたる。
INIT_START = time.time()

import json  # noqa: E402
import logging  # noqa: E402
import os  # noqa: E402
import random  # noqa: E402


def _uptime_seconds():
    """Return seconds since the host booted (from /proc/uptime), or None if unavailable."""
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


# 初期化が始まった時点で、ホストが起動してから何秒経っていたか(インスタンスを新しく起動したかの目安)。
UPTIME_AT_INIT = _uptime_seconds()


class _Collector(logging.Handler):
    """Keep vLLM log messages so the handler can return the init breakdown."""

    def __init__(self):
        super().__init__(level=logging.INFO)
        self.records = []

    def emit(self, record):
        self.records.append({"t": round(record.created - INIT_START, 3), "msg": record.getMessage()[:300]})


COLLECTOR = _Collector()
logging.getLogger("vllm").addHandler(COLLECTOR)

from vllm import LLM, SamplingParams  # noqa: E402

VLLM_IMPORTED = time.time()

MODEL_URI = os.environ["MODEL_URI"]
# 前回(g7e)の記事に合わせた設定。CUDA_GRAPH=0 なら Eager で動かす。
CUDA_GRAPH = os.environ.get("CUDA_GRAPH", "1") == "1"
ENGINE_ARGS = {
    "model": MODEL_URI,
    "load_format": os.environ.get("LOAD_FORMAT", "runai_streamer"),
    "max_model_len": int(os.environ.get("MAX_MODEL_LEN", "8192")),
    "max_num_seqs": 4,
    "max_num_batched_tokens": 4096,
    "gpu_memory_utilization": float(os.environ.get("GPU_MEMORY_UTILIZATION", "0.92")),
    "kv_cache_dtype": "fp8",
    # リクエストごとに異なる入力を作るので不要だが、念のためプレフィックスキャッシュの再利用を防ぐ。
    "enable_prefix_caching": False,
    "seed": 42,
    # FlashInfer は事前ビルドのカーネル(flashinfer-cubin)か nvcc がないと動かないので、Triton の Attention を使う。
    "attention_backend": "TRITON_ATTN",
}
if CUDA_GRAPH:
    ENGINE_ARGS["compilation_config"] = {"mode": 0, "cudagraph_mode": "FULL_DECODE_ONLY", "cudagraph_capture_sizes": [1, 2, 4]}
else:
    ENGINE_ARGS["enforce_eager"] = True
LLM_ENGINE = LLM(**ENGINE_ARGS)
TOKENIZER = LLM_ENGINE.get_tokenizer()
ENGINE_READY = time.time()
INIT_END = time.time()
INVOCATIONS = 0

MAX_INPUT_TOKENS = 8192 - 256
MAX_CONCURRENCY = 4


def _random_prompt(rng, n_tokens):
    """Build a prompt of exactly n_tokens token ids drawn from the normal vocabulary."""
    vocab = TOKENIZER.vocab_size
    return {"prompt_token_ids": [rng.randrange(1000, vocab - 1000) for _ in range(n_tokens)]}


def _bench(event):
    """Measure TTFT and output throughput for a batch of random prompts."""
    input_tokens = max(1, min(int(event.get("input_tokens", 254)), MAX_INPUT_TOKENS))
    max_tokens = max(2, min(int(event.get("max_tokens", 256)), 1024))
    concurrency = max(1, min(int(event.get("concurrency", 1)), MAX_CONCURRENCY))
    rounds = max(1, min(int(event.get("rounds", 5)), 10))
    rng = random.Random(event.get("seed", 42))

    results = []
    for _ in range(rounds):
        # TTFT は出力 1 トークンで生成した時間(Prefill + 最初の 1 トークン)で近似する。
        prompts = [_random_prompt(rng, input_tokens) for _ in range(concurrency)]
        t0 = time.perf_counter()
        LLM_ENGINE.generate(prompts, SamplingParams(max_tokens=1, temperature=0, ignore_eos=True), use_tqdm=False)
        ttft = time.perf_counter() - t0

        prompts = [_random_prompt(rng, input_tokens) for _ in range(concurrency)]
        t0 = time.perf_counter()
        outs = LLM_ENGINE.generate(prompts, SamplingParams(max_tokens=max_tokens, temperature=0, ignore_eos=True, seed=42), use_tqdm=False)
        e2e = time.perf_counter() - t0
        out_tokens = sum(len(o.outputs[0].token_ids) for o in outs)
        results.append(
            {
                "ttft_ms": round(ttft * 1000, 1),
                "e2e_seconds": round(e2e, 3),
                "output_tokens": out_tokens,
                # 1 リクエストあたりの E2E 速度と、並列分を合計した速度。
                "e2e_tok_per_sec": round(out_tokens / concurrency / e2e, 2),
                "decode_tok_per_sec": round((out_tokens / concurrency - 1) / max(e2e - ttft, 1e-6), 2),
                "aggregate_tok_per_sec": round(out_tokens / e2e, 2),
            }
        )
    return {"input_tokens": input_tokens, "max_tokens": max_tokens, "concurrency": concurrency, "rounds": results}


def _chat(event):
    """Generate a reply for a single user message."""
    prompt = str(event.get("prompt", "こんにちは"))[:4000]
    max_tokens = max(1, min(int(event.get("max_tokens", 256)), 1024))
    t0 = time.perf_counter()
    outs = LLM_ENGINE.chat([{"role": "user", "content": prompt}], SamplingParams(max_tokens=max_tokens, temperature=0), use_tqdm=False)
    return {"text": outs[0].outputs[0].text, "output_tokens": len(outs[0].outputs[0].token_ids), "seconds": round(time.perf_counter() - t0, 3)}


def handler(event, context):
    """Dispatch to chat or bench, and always include the init breakdown of this execution environment."""
    global INVOCATIONS
    INVOCATIONS += 1
    if not isinstance(event, dict):
        event = {}
    received = time.time()
    body = _bench(event) if event.get("mode") == "bench" else _chat(event)
    return {
        "invocation_in_this_env": INVOCATIONS,
        "received_epoch": received,
        "init": {
            "start_epoch": INIT_START,
            "end_epoch": INIT_END,
            "host_uptime_at_init_seconds": UPTIME_AT_INIT,
            "vllm_import_seconds": round(VLLM_IMPORTED - INIT_START, 3),
            "engine_init_seconds": round(ENGINE_READY - VLLM_IMPORTED, 3),
            "total_seconds": round(INIT_END - INIT_START, 3),
            "cuda_graph": CUDA_GRAPH,
            "load_format": ENGINE_ARGS["load_format"],
            # 返すのは初回の呼び出しだけ(ログの全文はレスポンスが大きくなるため)。
            "vllm_logs": COLLECTOR.records if INVOCATIONS == 1 else None,
        },
        "result": body,
    }


if __name__ == "__main__":
    print(json.dumps(handler({"prompt": "自己紹介して"}, None), ensure_ascii=False, indent=2))
