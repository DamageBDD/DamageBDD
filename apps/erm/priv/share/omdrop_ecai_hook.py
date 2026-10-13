# SPDX-License-Identifier: Apache-2.0
"""Optional completion hook for omdrop 0.16.1; loaded by the companion patch.

The explicit .ecai-events directory in the receive destination enables it.
It emits metadata only after an entire upload has been extracted successfully.
No commands, shell, URL fetches, or access to ECAI keys.
"""
import base64
import json
import logging
import os
import stat
import uuid


def completed(destination, names):
    events = os.path.join(destination, ".ecai-events")
    if not os.path.exists(events):
        return
    try:
        fd = os.open(events, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise OSError("unsafe completion directory")
            if len(os.listdir(fd)) + len(names) > 1024:
                raise OSError("completion queue full")
            for name in names:
                if not name or name in (".", "..") or os.path.basename(name) != name:
                    raise ValueError("invalid completed name")
                data = json.dumps({"v": 1, "transport": "airdrop",
                    "name_b64": base64.b64encode(os.fsencode(name)).decode("ascii")}).encode()
                stem = uuid.uuid4().hex
                temporary = stem + ".tmp"
                out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                              0o600, dir_fd=fd)
                try:
                    with os.fdopen(out, "wb") as stream:
                        stream.write(data)
                        stream.flush()
                        os.fsync(stream.fileno())
                    os.rename(temporary, stem + ".json", src_dir_fd=fd, dst_dir_fd=fd)
                    os.fsync(fd)
                finally:
                    try:
                        os.unlink(temporary, dir_fd=fd)
                    except FileNotFoundError:
                        pass
        finally:
            os.close(fd)
    except (OSError, ValueError):
        # The AirDrop transfer already succeeded. Preserve its original file;
        # expose a fixed diagnostic rather than retrying the network transfer.
        logging.error("ECAI completion event could not be saved; original retained")
