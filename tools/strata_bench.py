#!/usr/bin/env python3
"""Prefill and decode throughput against an OpenAI-compatible endpoint (Strata here).

  STRATA_URL=http://host:port/v1/chat/completions STRATA_API_KEY=... STRATA_MODEL=... \
  CORPUS_DIRS=dir1:dir2  ./strata_bench.py prefill [approx_prompt_tokens] [reps]
                         ./strata_bench.py decode  [max_tokens] [reps] [context_tokens]

prefill: unique (cache-busting) code prompt, max_tokens=1, prompt_tokens / wall time.
decode : streamed answer, (completion_tokens - 1) / (last token - first token).
The prompt corpus is every *.c / *.h under CORPUS_DIRS, concatenated in sorted
order (we used the nlzy/turing-unlock kernel/ dir and KohakUnlock checkouts).
"""
import json, os, pathlib, sys, time, urllib.request, uuid

URL = os.environ["STRATA_URL"]
KEY = os.environ.get("STRATA_API_KEY", "")
MODEL = os.environ.get("STRATA_MODEL", "qwen3.8-flash-next-coder-iq1_m")
TASK = ("Write a complete, well-commented Python module implementing an LRU cache with TTL expiry, "
        "a thread-safe wrapper, and pytest tests for both. Output only code.")


def corpus(tokens: int) -> str:
    files = []
    for d in os.environ.get("CORPUS_DIRS", "").split(":"):
        if d:
            files += sorted(pathlib.Path(os.path.expanduser(d)).rglob("*.[ch]"))
    text = "\n".join(f.read_text(errors="replace") for f in files)
    return text[: int(tokens * 3.2)]  # ~3.2 chars/token for C sources


def request(prompt: str, max_tokens: int, stream: bool):
    body = {"model": MODEL, "max_tokens": max_tokens, "temperature": 0,
            "messages": [{"role": "user", "content": prompt}]}
    if stream:
        body |= {"stream": True, "stream_options": {"include_usage": True}}
    req = urllib.request.Request(URL, json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
    return urllib.request.urlopen(req, timeout=1800)


def prefill(tokens=16000, reps=3):
    base = corpus(tokens)
    request(f"warm-up {uuid.uuid4()} say ok", 4, False).read()  # wakes a lazily loaded engine
    for _ in range(reps):
        t = time.monotonic()
        with request(f"nonce {uuid.uuid4()}\n{base}\n\nSummarize the code above in one word.", 1, False) as r:
            n = json.load(r)["usage"]["prompt_tokens"]
        dt = time.monotonic() - t
        print(f"prompt_tokens={n} seconds={dt:.2f} prefill_tok_s={n / dt:.1f}", flush=True)


def decode(max_tokens=512, reps=3, ctx=0):
    request(f"warm-up {uuid.uuid4()} say ok", 4, False).read()
    pre = f"{corpus(ctx)}\n\n" if ctx else ""
    for _ in range(reps):
        t0 = time.monotonic(); first = last = usage = None
        with request(f"nonce {uuid.uuid4()}\n{pre}{TASK}", max_tokens, True) as r:
            for raw in r:
                line = raw.decode().strip()
                if not line.startswith("data:") or line == "data: [DONE]":
                    continue
                ev = json.loads(line[5:])
                usage = ev.get("usage") or usage
                for ch in ev.get("choices", []):
                    d = ch.get("delta", {})
                    if d.get("content") or d.get("reasoning_content"):
                        last = time.monotonic(); first = first or last
        out = usage["completion_tokens"]
        print(f"prompt={usage['prompt_tokens']} ttft={first - t0:.2f}s gen={out} "
              f"decode_tok_s={(out - 1) / (last - first):.1f} total={last - t0:.1f}s", flush=True)


if __name__ == "__main__":
    mode, args = sys.argv[1], [int(a) for a in sys.argv[2:]]
    {"prefill": prefill, "decode": decode}[mode](*args)
