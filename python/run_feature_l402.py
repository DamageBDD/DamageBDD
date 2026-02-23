#!/usr/bin/env python3
# pip install pyl402
# export ALBY_BEARER_TOKEN="..."          # Alby API bearer token
# export DAMAGE_URL="http://localhost:8080/execute_feature/"
# python3 run_feature_l402.py features/ecai/sbrm.feature
import os
import sys

from pyl402.wallet import AlbyWallet
from pyl402.token_store import MemoryTokenStore
from pyl402.client import L402Client


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} path/to/feature.feature", file=sys.stderr)
        return 2

    url = os.getenv("DAMAGE_URL", "http://localhost:8080/execute_feature/")
    feature_path = sys.argv[1]

    with open(feature_path, "rb") as f:
        feature_bytes = f.read()

    # Wallet: pyl402 ships AlbyWallet out of the box.
    # Export: ALBY_BEARER_TOKEN="..."
    alby_token = os.getenv("ALBY_BEARER_TOKEN")
    if not alby_token:
        print("missing ALBY_BEARER_TOKEN env var", file=sys.stderr)
        return 2

    wallet = AlbyWallet(token=alby_token)
    store = MemoryTokenStore()

    # L402-capable HTTP client (httpx-like API)
    client = L402Client(wallet=wallet, store=store)

    # Cowboy handler accepts text/plain (from_html/2) and will run execute_bdd.
    # Use PUT to match your route.
    headers = {
        "content-type": "text/plain",
        # Optional: if you want concurrency control
        # "x-damage-concurrency": "1",
    }

    resp = client.put(url, content=feature_bytes, headers=headers)

    print(f"HTTP {resp.status_code}")
    # Prefer text; if JSON you'll still see it
    print(resp.text)
    return 0 if resp.status_code < 400 else 1


if __name__ == "__main__":
    raise SystemExit(main())
