#!/usr/bin/env python3
"""
nwc_l402_pynostr_reference.py

Reference smoke-test for:

  L402 challenge -> NIP-47 pay_invoice over Nostr -> retry execute_feature

Flow:
  1. POST /api/nwc/mint with a Bearer access token.
  2. Parse nostr+walletconnect://... URI.
  3. POST /execute_feature without auth and expect HTTP 402.
  4. Extract L402 macaroon + BOLT11 invoice from headers/body.
  5. Build a NIP-47 pay_invoice request event:
       kind    = 23194
       tags    = [["p", wallet_service_pubkey]]
       content = NIP-04 encrypted JSON: {"method":"pay_invoice","params":{"invoice":"..."}}
  6. Publish to all relays from the NWC URI.
  7. Subscribe for response:
       kind    = 23195
       author  = wallet_service_pubkey
       #e      = request_event_id
  8. Decrypt response, read preimage.
  9. Retry /execute_feature with:
       Authorization: L402 <macaroon>:<preimage>

Install:
  python -m venv .venv
  source .venv/bin/activate
  pip install 'pynostr[websocket-client]' requests cryptography coincurve tornado

Run:
  export DAMAGE_ACCESS_TOKEN='...'
  python nwc_l402_pynostr_reference.py \
    --base-url https://run.damagebdd.com \
    --access-token "$DAMAGE_ACCESS_TOKEN" \
    --verbose
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import uuid
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qs, quote, urljoin, urlparse

import requests
from pynostr.event import Event
from pynostr.filters import Filters, FiltersList
from pynostr.key import PrivateKey
from pynostr.relay_manager import RelayManager

NWC_REQUEST_KIND = 23194
NWC_RESPONSE_KIND = 23195

DEFAULT_RELAYS = [
    "wss://nostr-01.yakihonne.com",
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://nostr-02.yakihonne.com",
]

DEFAULT_FEATURE = """Feature: Paid test
  Scenario: simple run
    Given I set the variable "x" to "1"
    Then the variable "x" should be equal to JSON "1"
"""


class NwcError(RuntimeError):
    pass


@dataclass(frozen=True)
class NwcConnection:
    raw_uri: str
    wallet_pubkey: str
    secret_hex: str
    relays: list[str]

    @property
    def client_key(self) -> PrivateKey:
        return PrivateKey.from_hex(self.secret_hex)

    @property
    def client_pubkey(self) -> str:
        return self.client_key.public_key.hex()


@dataclass(frozen=True)
class NwcRequest:
    event: Event
    request_id: str
    method: str
    params: dict[str, Any]


def log(verbose: bool, message: str, *args: Any) -> None:
    if verbose:
        print(message.format(*args), file=sys.stderr, flush=True)


def api_url(base_url: str, path: str) -> str:
    # urljoin treats paths starting with "/" correctly.
    return urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))


def parse_nwc_uri(nwc_uri: str) -> NwcConnection:
    parsed = urlparse(nwc_uri)

    if parsed.scheme != "nostr+walletconnect":
        raise NwcError(f"expected nostr+walletconnect URI, got: {parsed.scheme}")

    wallet_pubkey = parsed.netloc or parsed.path.lstrip("/")
    query = parse_qs(parsed.query, keep_blank_values=True)

    # NIP-47 connection URIs may repeat relay= multiple times.
    relays = query.get("relay", [])
    secret = (query.get("secret") or [None])[0]

    if not wallet_pubkey or not re.fullmatch(r"[0-9a-fA-F]{64}", wallet_pubkey):
        raise NwcError(f"invalid wallet pubkey in NWC URI: {wallet_pubkey!r}")
    if not secret or not re.fullmatch(r"[0-9a-fA-F]{64}", secret):
        raise NwcError("missing or invalid NWC secret= hex token")
    if not relays:
        raise NwcError("NWC URI has no relay= entries; wallet service may be unreachable")

    return NwcConnection(
        raw_uri=nwc_uri,
        wallet_pubkey=wallet_pubkey.lower(),
        secret_hex=secret.lower(),
        relays=[r for r in relays if r],
    )


def build_nwc_uri(wallet_pubkey: str, relays: list[str], secret_hex: str) -> str:
    qs = "".join(f"&relay={quote(r, safe=':/')}" for r in relays)
    # Keep secret last for readability. Strip first '&' by starting with '?' manually.
    return f"nostr+walletconnect://{wallet_pubkey}?{qs.lstrip('&')}&secret={secret_hex}"


def build_nwc_request(conn: NwcConnection, method: str, params: dict[str, Any]) -> NwcRequest:
    payload = json.dumps(
        {"method": method, "params": params},
        separators=(",", ":"),
        ensure_ascii=False,
    )

    # DamageBDD's current Erlang NWC client uses the legacy NIP-04 envelope.
    encrypted = conn.client_key.encrypt_message(payload, conn.wallet_pubkey)

    event = Event(
        content=encrypted,
        kind=NWC_REQUEST_KIND,
        tags=[["p", conn.wallet_pubkey]],
    )
    event.sign(conn.secret_hex)

    if not event.id:
        raise NwcError("pynostr did not compute a request event id")

    return NwcRequest(event=event, request_id=event.id, method=method, params=params)


def decrypt_nwc_response(conn: NwcConnection, event: Event) -> dict[str, Any]:
    if event.pubkey != conn.wallet_pubkey:
        raise NwcError(f"response author mismatch: {event.pubkey} != {conn.wallet_pubkey}")
    cleartext = conn.client_key.decrypt_message(event.content, conn.wallet_pubkey)
    decoded = json.loads(cleartext)
    if not isinstance(decoded, dict):
        raise NwcError(f"NWC response is not an object: {decoded!r}")
    return decoded


def new_relay_manager(relays: list[str], timeout: float = 8.0) -> RelayManager:
    manager = RelayManager(timeout=timeout)
    for relay in relays:
        manager.add_relay(relay, timeout=timeout, close_on_eose=False)
    return manager


def publish_and_wait_for_response(
    conn: NwcConnection,
    req: NwcRequest,
    *,
    timeout_s: float,
    relay_timeout_s: float,
    verbose: bool,
) -> dict[str, Any]:
    manager = new_relay_manager(conn.relays, timeout=relay_timeout_s)

    since = int(time.time()) - 5
    filters = FiltersList(
        [
            Filters(
                kinds=[NWC_RESPONSE_KIND],
                authors=[conn.wallet_pubkey],
                event_refs=[req.request_id],
                since=since,
                limit=1,
            )
        ]
    )

    subscription_id = "damage-nwc-" + uuid.uuid4().hex
    manager.add_subscription_on_all_relays(subscription_id, filters)

    log(verbose, "NWC request id: {}", req.request_id)
    log(verbose, "NWC client pubkey: {}", conn.client_pubkey)
    log(verbose, "NWC wallet pubkey: {}", conn.wallet_pubkey)
    log(verbose, "NWC relays: {}", ", ".join(conn.relays))

    # pynostr examples publish before run_sync(); relay_manager.run_sync() connects and flushes.
    manager.publish_event(req.event)
    manager.run_sync()

    deadline = time.monotonic() + timeout_s
    last_notice: Any = None
    last_ok: Any = None

    try:
        while time.monotonic() < deadline:
            while manager.message_pool.has_ok_notices():
                last_ok = manager.message_pool.get_ok_notice()
                log(verbose, "relay OK: {}", last_ok)

            while manager.message_pool.has_notices():
                last_notice = manager.message_pool.get_notice()
                log(verbose, "relay NOTICE: {}", last_notice)

            while manager.message_pool.has_events():
                msg = manager.message_pool.get_event()
                event = msg.event
                if (
                    event.kind == NWC_RESPONSE_KIND
                    and event.pubkey == conn.wallet_pubkey
                    and any(tag[:2] == ["e", req.request_id] for tag in event.tags)
                ):
                    response = decrypt_nwc_response(conn, event)
                    log(verbose, "NWC response: {}", json.dumps(response, indent=2))
                    return response

            time.sleep(0.25)

        raise NwcError(
            "timed out waiting for NWC response "
            f"(last_ok={last_ok!r}, last_notice={last_notice!r})"
        )
    finally:
        manager.close_subscription_on_all_relays(subscription_id)
        manager.close_all_relay_connections()


def extract_l402_challenge(resp: requests.Response) -> tuple[str, str]:
    """
    Returns (macaroon, invoice_bolt11).

    Supports common L402 / LSAT shapes:
      WWW-Authenticate: L402 macaroon="...", invoice="..."
      WWW-Authenticate: LSAT macaroon="...", invoice="..."
      X-L402-Macaroon / X-L402-Invoice
      X-Macaroon / X-Lightning-Invoice
      JSON bodies with macaroon + invoice/bolt11/payment_request
    """
    header_blob = "\n".join(f"{k}: {v}" for k, v in resp.headers.items())

    def header_any(*names: str) -> str | None:
        wanted = {n.lower() for n in names}
        for k, v in resp.headers.items():
            if k.lower() in wanted:
                return v
        return None

    auth = header_any("www-authenticate", "WWW-Authenticate") or ""

    macaroon = (
        header_any("x-l402-macaroon", "x-macaroon", "macaroon")
        or _regex_value(auth, r'\bmacaroon="?([^",\s]+)"?')
        or _regex_value(header_blob, r'\bmacaroon="?([^",\s]+)"?')
    )

    invoice = (
        header_any(
            "x-l402-invoice",
            "x-lightning-invoice",
            "lightning-invoice",
            "bolt11",
            "invoice",
        )
        or _regex_value(auth, r'\binvoice="?([^",\s]+)"?')
        or _regex_value(auth, r'\bbolt11="?([^",\s]+)"?')
        or _regex_value(header_blob, r'\b(invoice|bolt11)="?([^",\s]+)"?', group=2)
    )

    if (not macaroon or not invoice) and resp.content:
        try:
            body = resp.json()
            if isinstance(body, dict):
                macaroon = macaroon or _find_first_key(body, ["macaroon", "l402_macaroon"])
                invoice = invoice or _find_first_key(
                    body,
                    ["invoice", "bolt11", "payment_request", "invoice_bolt11"],
                )
        except Exception:
            # Body is often text/plain for challenge responses.
            pass

    if not macaroon or not invoice:
        raise NwcError(
            "could not extract L402 macaroon + invoice from 402 response\n"
            f"status={resp.status_code}\nheaders={dict(resp.headers)}\nbody={resp.text[:2000]}"
        )

    return str(macaroon), str(invoice)


def _regex_value(text: str, pattern: str, group: int = 1) -> str | None:
    match = re.search(pattern, text, re.IGNORECASE)
    return match.group(group) if match else None


def _find_first_key(obj: Any, keys: list[str]) -> str | None:
    if isinstance(obj, dict):
        lower = {str(k).lower(): v for k, v in obj.items()}
        for key in keys:
            if key.lower() in lower:
                return str(lower[key])
        for v in obj.values():
            found = _find_first_key(v, keys)
            if found:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = _find_first_key(item, keys)
            if found:
                return found
    return None


def mint_nwc_wallet(
    base_url: str,
    access_token: str,
    relays: list[str],
    *,
    max_single_sat: int,
    max_total_sat: int,
    expires_height: int,
    verify_tls: bool,
    verbose: bool,
) -> NwcConnection:
    url = api_url(base_url, "/api/nwc/mint")
    body = {
        "relays": relays,
        "max_single_sat": max_single_sat,
        "max_total_sat": max_total_sat,
        "expires_height": expires_height,
    }
    headers = {
        "authorization": f"Bearer {access_token}",
        "content-type": "application/json",
        "accept": "application/json",
        "user-agent": "damagebdd-pynostr-nwc-reference/0.1",
    }

    log(verbose, "POST {} {}", url, json.dumps(body))
    resp = requests.post(url, headers=headers, json=body, timeout=30, verify=verify_tls)
    if resp.status_code != 200:
        raise NwcError(f"mint failed: HTTP {resp.status_code}\n{resp.text[:2000]}")

    data = resp.json()
    nwc_uri = data.get("nwc_uri")
    if not nwc_uri:
        raise NwcError(f"mint response did not contain nwc_uri: {data}")

    conn = parse_nwc_uri(nwc_uri)
    log(verbose, "minted NWC URI for wallet pubkey {}", conn.wallet_pubkey)
    return conn


def call_execute_feature(
    base_url: str,
    path: str,
    feature: str,
    *,
    authorization: str | None,
    verify_tls: bool,
    verbose: bool,
) -> requests.Response:
    url = api_url(base_url, path)
    headers = {
        "content-type": "text/plain",
        "accept": "application/json,text/plain,*/*",
        "user-agent": "damagebdd-pynostr-nwc-reference/0.1",
    }
    if authorization:
        headers["authorization"] = authorization

    log(verbose, "POST {} auth={}", url, "yes" if authorization else "no")
    return requests.post(
        url,
        headers=headers,
        data=feature.encode("utf-8"),
        timeout=120,
        verify=verify_tls,
    )


def get_payment_preimage(nwc_response: dict[str, Any]) -> str:
    if nwc_response.get("error"):
        raise NwcError(f"NWC payment error: {nwc_response['error']}")

    # NIP-47 normal shape: {"result_type":"pay_invoice","error":null,"result":{"preimage":"..."}}
    result = nwc_response.get("result")
    if isinstance(result, dict) and result.get("preimage"):
        return str(result["preimage"])

    # DamageBDD step text stores "$.preimage" from resp_pay, so tolerate flattened responses too.
    if nwc_response.get("preimage"):
        return str(nwc_response["preimage"])

    raise NwcError(f"NWC response does not contain payment preimage: {nwc_response}")


def run(args: argparse.Namespace) -> int:
    access_token = args.access_token or os.environ.get("DAMAGE_ACCESS_TOKEN")
    if not access_token:
        raise NwcError("provide --access-token or set DAMAGE_ACCESS_TOKEN")

    verify_tls = not args.insecure

    feature = Path(args.feature_file).read_text() if args.feature_file else DEFAULT_FEATURE

    conn = mint_nwc_wallet(
        args.base_url,
        access_token,
        args.relays,
        max_single_sat=args.max_single_sat,
        max_total_sat=args.max_total_sat,
        expires_height=args.expires_height,
        verify_tls=verify_tls,
        verbose=args.verbose,
    )

    # The paid endpoint must be called without Bearer auth, matching the BDD scenario.
    challenge = call_execute_feature(
        args.base_url,
        args.challenge_path,
        feature,
        authorization=None,
        verify_tls=verify_tls,
        verbose=args.verbose,
    )

    if challenge.status_code != 402:
        raise NwcError(
            f"expected execute_feature challenge HTTP 402, got {challenge.status_code}\n"
            f"headers={dict(challenge.headers)}\nbody={challenge.text[:2000]}"
        )

    macaroon, invoice = extract_l402_challenge(challenge)
    print(f"challenge_status={challenge.status_code}")
    print(f"invoice_bolt11={invoice}")
    print(f"macaroon={macaroon}")

    req = build_nwc_request(conn, "pay_invoice", {"invoice": invoice})
    nwc_response = publish_and_wait_for_response(
        conn,
        req,
        timeout_s=args.nwc_timeout,
        relay_timeout_s=args.relay_timeout,
        verbose=args.verbose,
    )
    preimage = get_payment_preimage(nwc_response)
    print(f"payment_preimage={preimage}")

    paid = call_execute_feature(
        args.base_url,
        args.paid_path,
        feature,
        authorization=f"L402 {macaroon}:{preimage}",
        verify_tls=verify_tls,
        verbose=args.verbose,
    )

    print(f"paid_status={paid.status_code}")
    print(paid.text)

    if paid.status_code != 200:
        raise NwcError(f"expected paid execute_feature HTTP 200, got {paid.status_code}")

    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="DamageBDD L402/NIP-47/pynostr reference test")
    p.add_argument("--base-url", default="https://run.damagebdd.com")
    p.add_argument("--access-token", default=None)
    p.add_argument("--relay", dest="relays", action="append", default=None)
    p.add_argument("--max-single-sat", type=int, default=1000)
    p.add_argument("--max-total-sat", type=int, default=5000)
    p.add_argument("--expires-height", type=int, default=0)
    p.add_argument("--challenge-path", default="/execute_feature")
    p.add_argument("--paid-path", default="/execute_feature/")
    p.add_argument("--feature-file", default=None)
    p.add_argument("--nwc-timeout", type=float, default=65.0)
    p.add_argument("--relay-timeout", type=float, default=8.0)
    p.add_argument("--insecure", action="store_true", help="disable TLS certificate verification")
    p.add_argument("--verbose", action="store_true")
    return p


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()
    if args.relays is None:
        args.relays = DEFAULT_RELAYS

    try:
        return run(args)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
