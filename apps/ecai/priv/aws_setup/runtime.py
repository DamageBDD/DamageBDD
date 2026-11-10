#!/usr/bin/env python3
"""Node-local Python runtime bootstrap. No AWS SDK clients or credential input.

Erlang sends one bounded JSON settings line on stdin. Subsequent EOF cancels
work. Stdout is a small JSON event stream; subprocess output is never relayed.
Environments are built at their FINAL path (venvs are not relocatable). Only a
verified generation is selected, by atomically replacing a small JSON pointer.
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import signal
import shutil
import stat
import subprocess
import sys
import threading
import time
import uuid

SCHEMA = 1
REQUIREMENTS = Path(__file__).with_name("requirements.txt")
CANCEL = threading.Event()
MAX_PACKET = 16384


class Failure(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def emit(phase: str, **fields) -> None:
    print(json.dumps({"phase": phase, **fields}, separators=(",", ":")), flush=True)


def pins() -> tuple[bytes, dict[str, str]]:
    try:
        raw = REQUIREMENTS.read_bytes()
        if not 0 < len(raw) <= MAX_PACKET:
            raise ValueError()
        result = {}
        for line in raw.decode("utf-8").splitlines():
            value = line.split("#", 1)[0].strip()
            if not value:
                continue
            match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+!-]+)", value)
            if not match or match[1] in result:
                raise ValueError()
            result[match[1]] = match[2]
        if "boto3" not in result:
            raise ValueError()
        return raw, result
    except (OSError, ValueError, UnicodeError):
        raise Failure("invalid_requirements") from None


def clean_env() -> dict[str, str]:
    # Do not pass node AWS credentials, proxies, PYTHONPATH, pip indexes or tokens
    # to package installation. PIP_CONFIG_FILE disables even system pip config.
    return {"PATH": os.defpath, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "PIP_CONFIG_FILE": os.devnull, "NETRC": os.devnull, "AWS_EC2_METADATA_DISABLED": "true"}


def remaining(deadline: float) -> float:
    if CANCEL.is_set():
        raise Failure("runtime_cancelled")
    left = deadline - time.monotonic()
    if left <= 0:
        raise Failure("runtime_timeout")
    return left


def run(args: list[str], deadline: float, code: str, capture: bool = False) -> bytes:
    """Bounded child lifecycle; kill the entire group on timeout/port closure."""
    remaining(deadline)
    try:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, env=clean_env(),
                                   start_new_session=True)
    except OSError:
        raise Failure(code) from None
    try:
        while True:
            try:
                output, _ = process.communicate(timeout=min(.25, remaining(deadline)))
                break
            except subprocess.TimeoutExpired:
                continue
        if process.returncode != 0:
            raise Failure(code)
        if output and len(output) > MAX_PACKET:
            raise Failure("invalid_health_output")
        return output or b""
    finally:
        if process.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def verify(python: str, deadline: float, managed: bool) -> dict:
    output = run([python, "-I", "-u", str(Path(__file__).resolve()), "--verify",
                  "managed" if managed else "external"], deadline, "dependency_check_failed", True)
    try:
        result = json.loads(output)
        if result.get("ok") is not True or not isinstance(result.get("versions"), dict):
            raise ValueError()
    except (ValueError, TypeError):
        raise Failure("invalid_health_output") from None
    run([python, "-I", "-m", "pip", "--isolated", "--disable-pip-version-check", "check"],
        deadline, "pip_check_failed")
    return result


def verify_current() -> int:
    # Runs in the candidate interpreter, not the installer interpreter.
    try:
        _, required = pins()
        if sys.version_info < (3, 11):
            raise Failure("python_too_old")
        if sys.argv[-1] == "managed" and sys.prefix == sys.base_prefix:
            raise Failure("not_a_virtualenv")
        for name, version in required.items():
            if importlib.metadata.version(name) != version:
                raise Failure("dependency_version_mismatch")
        import boto3
        import botocore
        from botocore.config import Config  # noqa: F401
        from botocore.exceptions import ClientError  # noqa: F401
        print(json.dumps({"ok": True, "versions": {"python": sys.version.split()[0],
              "boto3": boto3.__version__, "botocore": botocore.__version__}}), flush=True)
        return 0
    except Exception:
        # Never print package exception text, environment variables or file paths.
        return 1


def secure_root(root: Path) -> None:
    if not root.is_absolute() or root.is_symlink() or root == Path("/"):
        raise Failure("unsafe_runtime_directory")
    try:
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise Failure("unsafe_runtime_directory")
    except PermissionError:
        raise Failure("runtime_directory_not_writable") from None
    except OSError:
        raise Failure("runtime_directory_unavailable") from None


def safe_file(path: Path) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
                raise Failure("unsafe_runtime_directory")
            data = handle.read(MAX_PACKET + 1)
            if len(data) > MAX_PACKET:
                raise Failure("invalid_runtime_manifest")
            return data
    except FileNotFoundError:
        raise
    except OSError:
        raise Failure("unsafe_runtime_directory") from None


def atomic_json(path: Path, data: dict) -> None:
    temp = path.with_name(".write-" + uuid.uuid4().hex)
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp.unlink()


@contextlib.contextmanager
def locked(root: Path, deadline: float):
    secure_root(root)
    try:
        fd = os.open(root / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError:
        raise Failure("runtime_directory_not_writable") from None
    with os.fdopen(fd, "r+") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise Failure("unsafe_runtime_directory")
        while True:
            remaining(deadline)
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                emit("waiting_for_lock")
                time.sleep(min(1, remaining(deadline)))
        # Flock is released by the kernel even if the VM/helper dies.
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def generation(root: Path, fingerprint: str) -> Path | None:
    try:
        record = json.loads(safe_file(root / "current.json"))
        name = record.get("environment", "")
        if record.get("fingerprint") != fingerprint:
            return None
        if not re.fullmatch(r"env-[a-f0-9]{20}-[a-f0-9]{12}", name):
            raise Failure("invalid_runtime_manifest")
        env = root / name
        info = env.lstat()
        if env.is_symlink() or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise Failure("unsafe_runtime_directory")
        marker = json.loads(safe_file(env / ".ecai-runtime.json"))
        if marker != {"schema": SCHEMA, "fingerprint": fingerprint, "path": str(env)}:
            raise Failure("invalid_runtime_manifest")
        return env
    except FileNotFoundError:
        return None
    except (ValueError, TypeError, AttributeError):
        raise Failure("invalid_runtime_manifest") from None


def ensure(settings: dict) -> dict:
    if not isinstance(settings, dict) or set(settings) - {"mode", "root", "python", "install", "wheelhouse", "timeout_seconds"}:
        raise Failure("invalid_runtime_settings")
    timeout = settings.get("timeout_seconds", 600)
    if type(timeout) is not int or not 10 <= timeout <= 1800:
        raise Failure("invalid_runtime_settings")
    deadline = time.monotonic() + timeout
    if sys.version_info < (3, 11):
        raise Failure("python_too_old")
    raw, _ = pins()
    if settings.get("mode") == "external":
        python = settings.get("python")
        if not isinstance(python, str) or not Path(python).is_absolute():
            raise Failure("invalid_external_interpreter")
        emit("checking")
        result = verify(python, deadline, False)
        return {"python": python, "mode": "external", "versions": result["versions"], "reused": True}
    if settings.get("mode") != "managed" or type(settings.get("install")) is not bool:
        raise Failure("invalid_runtime_settings")
    root = Path(settings.get("root", ""))
    # The root is operator-controlled. Resolve its parent to support legitimate
    # mounts; reject a symlink at the actual managed root, never follow pointers.
    if not root.is_absolute():
        raise Failure("unsafe_runtime_directory")
    if root.is_symlink():
        raise Failure("unsafe_runtime_directory")
    root = root.parent.resolve() / root.name
    fingerprint = hashlib.sha256(raw + json.dumps({"schema": SCHEMA, "base": sys.base_prefix,
        "python": list(sys.version_info[:3]), "executable": os.path.realpath(sys.executable)}, sort_keys=True).encode()).hexdigest()
    with locked(root, deadline):
        existing = generation(root, fingerprint)
        if existing:
            emit("checking")
            try:
                result = verify(str(existing / "bin/python"), deadline, True)
                return {"python": str(existing / "bin/python"), "mode": "managed", "versions": result["versions"], "reused": True}
            except Failure as exc:
                if exc.code in {"runtime_cancelled", "runtime_timeout"}:
                    raise
                if not settings["install"]:
                    raise
        if not settings["install"]:
            raise Failure("automatic_install_disabled")
        wheelhouse = settings.get("wheelhouse", "")
        if not isinstance(wheelhouse, str) or (wheelhouse and (not Path(wheelhouse).is_absolute() or not Path(wheelhouse).is_dir())):
            raise Failure("invalid_wheelhouse")
        # Build at the final unique path; never rename or mutate an existing venv.
        env = root / ("env-" + fingerprint[:20] + "-" + uuid.uuid4().hex[:12])
        env.mkdir(mode=0o700)
        atomic_json(env / ".ecai-runtime.json", {"schema": SCHEMA, "fingerprint": fingerprint, "path": str(env)})
        try:
            emit("creating")
            run([sys.executable, "-I", "-m", "venv", str(env)], deadline, "venv_creation_failed")
            python = str(env / "bin/python")
            emit("installing")
            command = [python, "-I", "-m", "pip", "--isolated", "--disable-pip-version-check",
                       "--no-input", "install", "--no-cache-dir", "--only-binary=:all:",
                       "--timeout", "20", "--retries", "1"]
            if wheelhouse:
                command += ["--no-index", "--find-links", wheelhouse]
            else:
                command += ["--index-url", "https://pypi.org/simple"]
            command += ["-r", str(REQUIREMENTS)]
            run(command, deadline, "dependency_install_failed")
            emit("verifying")
            result = verify(python, deadline, True)
            remaining(deadline)
            atomic_json(root / "current.json", {"schema": SCHEMA, "fingerprint": fingerprint, "environment": env.name})
            return {"python": python, "mode": "managed", "versions": result["versions"], "reused": False}
        except BaseException:
            # The lock and private root prevent another bootstrap from changing
            # this newly allocated path. Never delete older or explicit envs.
            if not env.is_symlink():
                shutil.rmtree(env, ignore_errors=True)
            raise


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--verify":
        return verify_current()
    try:
        signal.signal(signal.SIGTERM, lambda *_: CANCEL.set())
        signal.signal(signal.SIGINT, lambda *_: CANCEL.set())
        os.umask(0o077)
        line = sys.stdin.buffer.readline(MAX_PACKET + 1)
        if not line.endswith(b"\n") or len(line) > MAX_PACKET:
            raise Failure("invalid_runtime_settings")
        settings = json.loads(line)
        # Erlang holds stdin open while the worker is alive. A closed port/VM
        # cancels even a package subprocess, and releases the cross-VM lock.
        def watch_parent():
            os.read(sys.stdin.fileno(), 1)
            CANCEL.set()
        threading.Thread(target=watch_parent, daemon=True).start()
        result = ensure(settings)
        emit("ready", ok=True, **result)
        return 0
    except Failure as exc:
        emit("failed", ok=False, error=exc.code)
        return 1
    except (Exception, KeyboardInterrupt):
        emit("failed", ok=False, error="runtime_bootstrap_failed")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
