#!/usr/bin/env python3
"""Executable integration test for the packet-4 production protocol."""
import json
import os
import pathlib
import struct
import subprocess
import sys
import tempfile


def packet(process: subprocess.Popen[bytes], payload: bytes) -> bytes:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(struct.pack(">I", len(payload)) + payload)
    process.stdin.flush()
    header = process.stdout.read(4)
    if len(header) != 4:
        raise AssertionError("backend closed before response")
    size = struct.unpack(">I", header)[0]
    response = process.stdout.read(size)
    if len(response) != size:
        raise AssertionError("truncated backend response")
    return response


def start(binary: pathlib.Path) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        [str(binary), "--framed"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def initialize(process: subprocess.Popen[bytes], vault: pathlib.Path, mode: str) -> None:
    init = b"\x00" + json.dumps(
        {
            "protocol": "damage-nsecbunker-port-v2",
            "vault_path": str(vault),
            "vault_mode": mode,
            "production": True,
        },
        separators=(",", ":"),
    ).encode()
    assert packet(process, init) == b"\x80\x00"


def close_cleanly(process: subprocess.Popen[bytes]) -> None:
    assert process.stdin is not None
    process.stdin.close()
    assert process.wait(timeout=5) == 0


def public_key(process: subprocess.Popen[bytes]) -> dict[str, object]:
    request_id = os.urandom(16)
    response = packet(process, b"\x02" + request_id + b'{"op":"get_public_key"}')
    assert response[:2] == b"\x82\x00"
    assert response[2:18] == request_id
    envelope = json.loads(response[18:])
    assert envelope["ok"] is True
    return envelope["result"]


def main() -> int:
    binary = pathlib.Path(
        sys.argv[1] if len(sys.argv) > 1 else "./damage-nsecbunker-crypto-c"
    ).resolve()
    with tempfile.TemporaryDirectory() as directory:
        vault = pathlib.Path(directory) / "node.vault"
        passphrase = b"framed-integration-passphrase"

        create = start(binary)
        initialize(create, vault, "create_if_missing")
        unlock = packet(create, b"\x01" + passphrase)
        assert unlock[:2] == b"\x81\x00"
        metadata = json.loads(unlock[2:])
        assert metadata["vault_created"] is True
        assert vault.stat().st_mode & 0o777 == 0o600
        created_identity = public_key(create)

        # A production operation cannot select another vault.
        bad_id = os.urandom(16)
        rejected = packet(
            create,
            b"\x02" + bad_id + b'{"op":"get_public_key","vault_path":"/tmp/other"}',
        )
        assert rejected[:2] == b"\x82\x01"
        assert rejected[2:18] == bad_id

        environ = pathlib.Path(f"/proc/{create.pid}/environ").read_bytes()
        cmdline = pathlib.Path(f"/proc/{create.pid}/cmdline").read_bytes()
        assert passphrase not in environ
        assert passphrase not in cmdline
        close_cleanly(create)

        reopen = start(binary)
        initialize(reopen, vault, "open_existing")
        reopened = packet(reopen, b"\x01" + passphrase)
        assert reopened[:2] == b"\x81\x00"
        reopened_metadata = json.loads(reopened[2:])
        assert reopened_metadata["vault_created"] is False
        assert public_key(reopen)["pubkey_hex"] == created_identity["pubkey_hex"]
        close_cleanly(reopen)

        wrong = start(binary)
        initialize(wrong, vault, "open_existing")
        assert packet(wrong, b"\x01wrong-passphrase") == b"\x81\x01vault_unlock_failed"
        close_cleanly(wrong)

    print("framed protocol integration: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
