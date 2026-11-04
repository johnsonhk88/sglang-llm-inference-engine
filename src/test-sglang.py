#!/usr/bin/env python3
"""
Test script for the SGLang OpenAI-compatible serving API.

Usage:
    python3 src/test-sglang.py [options]

Examples:
    python3 src/test-sglang.py --mode models
    python3 src/test-sglang.py --mode chat --model qwen-small
    python3 src/test-sglang.py --mode all
"""

from __future__ import annotations

import argparse
import json
import sys

try:
    import requests
except ImportError:
    print("Error: 'requests' library is required. Install via: pip install requests", file=sys.stderr)
    sys.exit(1)

LITELLM_AVAILABLE = False
try:
    import litellm  # type: ignore

    LITELLM_AVAILABLE = True
except ImportError:
    pass

DEFAULT_BASE_URL = "http://localhost:30000/v1"


def get_available_models(base_url: str) -> list[str]:
    url = f"{base_url.rstrip('/')}/models"
    try:
        resp = requests.get(url, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        return [m.get("id") for m in data.get("data", []) if m.get("id")]
    except Exception as exc:
        print(f"[!] Failed to connect to server at {url}: {exc}", file=sys.stderr)
        return []


def test_health(base_url: str) -> bool:
    root = base_url.rstrip("/").removesuffix("/v1")
    url = f"{root}/health"
    print(f"\n--- Health ({url}) ---")
    try:
        resp = requests.get(url, timeout=15)
        resp.raise_for_status()
        print(f"[+] Health OK (HTTP {resp.status_code})")
        return True
    except Exception as exc:
        print(f"[-] Health check failed: {exc}", file=sys.stderr)
        return False


def test_models(base_url: str) -> str | None:
    print(f"\n--- Checking Server Models ({base_url}/models) ---")
    models = get_available_models(base_url)
    if not models:
        print("[-] No models found or server is not reachable.")
        return None
    print(f"[+] Server is UP! Found {len(models)} model(s):")
    for model in models:
        print(f"    - {model}")
    return models[0]


def test_chat(base_url: str, model: str, prompt: str) -> bool:
    print(f"\n--- Chat Completions (model={model}) ---")
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 64,
        "temperature": 0.0,
    }

    if LITELLM_AVAILABLE:
        try:
            response = litellm.completion(
                model=f"openai/{model}",
                api_base=base_url,
                api_key="none",
                messages=payload["messages"],
                max_tokens=payload["max_tokens"],
                temperature=payload["temperature"],
            )
            content = response.choices[0].message.content
            print("[+] LiteLLM chat OK")
            print(content)
            return bool(content)
        except Exception as exc:
            print(f"[!] LiteLLM failed, falling back to HTTP: {exc}")

    url = f"{base_url.rstrip('/')}/chat/completions"
    try:
        resp = requests.post(url, json=payload, timeout=120)
        resp.raise_for_status()
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        print("[+] HTTP chat OK")
        print(content)
        return bool(content)
    except Exception as exc:
        print(f"[-] Chat request failed: {exc}", file=sys.stderr)
        return False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Test SGLang OpenAI-compatible API")
    parser.add_argument("--url", default=DEFAULT_BASE_URL, help="OpenAI API base URL")
    parser.add_argument(
        "--mode",
        choices=["health", "models", "chat", "all"],
        default="all",
        help="Test mode",
    )
    parser.add_argument("--model", default="", help="API-visible model name")
    parser.add_argument(
        "--prompt",
        default="Reply with the exact word PONG and nothing else.",
        help="Chat prompt",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    failed = 0

    if args.mode in ("health", "all"):
        if not test_health(args.url):
            failed += 1
            if args.mode == "all":
                return 1

    discovered = None
    if args.mode in ("models", "chat", "all"):
        discovered = test_models(args.url)
        if not discovered and args.mode in ("models", "all"):
            failed += 1
            if args.mode != "chat":
                return 1 if failed else 0

    if args.mode in ("chat", "all"):
        model = args.model or discovered
        if not model:
            print("[-] No model name available for chat test.", file=sys.stderr)
            return 1
        if not test_chat(args.url, model, args.prompt):
            failed += 1

    if failed:
        print("\n[-] Some tests failed.", file=sys.stderr)
        return 1
    print("\n[+] All requested tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
