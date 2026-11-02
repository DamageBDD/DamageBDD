#!/usr/bin/env python3
"""Exercise the real build hook with local SDK stubs, not installed speech SDKs."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ERM = HERE.parent.parent


def run(args, env):
    result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    if result.returncode:
        raise AssertionError(f"{args!r} failed ({result.returncode}):\n{result.stdout}")
    return result.stdout


with tempfile.TemporaryDirectory(prefix="erm phrase build ") as temp:
    base = Path(temp)
    app = base / "app"
    (app / "scripts").mkdir(parents=True)
    (app / "c_src").mkdir()
    for name in ["build_native_voice.sh", "setup_native_voice.sh"]:
        shutil.copy2(ERM / "scripts" / name, app / "scripts" / name)
    for name in ["Makefile.native_voice", "Makefile.phrase_lab", "erm_native_voice.cpp",
                 "erm_voice_audio.h", "erm_phrase_features.h", "erm_phrase_synth.h",
                 "erm_phrase_lab_port.cpp"]:
        shutil.copy2(ERM / "c_src" / name, app / "c_src" / name)
    sdk = base / "sdk with spaces"
    (sdk / "lib").mkdir(parents=True)
    shutil.copytree(HERE / "sdk", sdk / "include")
    empty = base / "empty.c"
    empty.write_text("void erm_test_sdk_boundary(void) {}\n")
    env = os.environ.copy()
    env.update(WHISPER_PREFIX=str(sdk), SHERPA_PREFIX=str(sdk),
               ERM_NATIVE_VOICE_AUTO_SETUP="0", XDG_CACHE_HOME=str(base / "cache"),
               CXXFLAGS="-O1 -Wall -Wextra -Werror", CPPFLAGS="", LDFLAGS="")
    cc = env.get("CC", "cc")
    for library in ["libwhisper.so", "libsherpa-onnx-c-api.so"]:
        run([cc, "-shared", "-fPIC", str(empty), "-o", str(sdk / "lib" / library)], env)
    command = ["sh", str(app / "scripts" / "build_native_voice.sh")]
    capture = app / "priv" / "erm_native_voice"
    lab = app / "priv" / "erm_phrase_lab"
    metadata = app / "c_src" / ".erm_native_voice.build"
    run(command + ["compile"], env)
    assert capture.is_file() and os.access(capture, os.X_OK)
    assert lab.is_file() and os.access(lab, os.X_OK)
    assert capture.read_bytes() != lab.read_bytes(), "recursive make overwrote capture target"
    assert metadata.is_file()
    print("PASS ordinary build hook creates distinct capture and synthesis executables with spaced SDK paths")

    first = (capture.stat().st_mtime_ns, lab.stat().st_mtime_ns)
    run(command + ["compile"], env)
    assert first == (capture.stat().st_mtime_ns, lab.stat().st_mtime_ns)
    print("PASS unchanged native build is incremental")

    time.sleep(0.03)
    (app / "c_src" / "erm_phrase_synth.h").touch()
    run(command + ["compile"], env)
    second = (capture.stat().st_mtime_ns, lab.stat().st_mtime_ns)
    assert all(after > before for after, before in zip(second, first))
    print("PASS synthesis header change rebuilds both dependent executables")

    changed = env.copy()
    changed["CXXFLAGS"] += " -DERM_BUILD_INTEGRATION_TEST=1"
    run(command + ["compile"], changed)
    third = (capture.stat().st_mtime_ns, lab.stat().st_mtime_ns)
    assert all(after > before for after, before in zip(third, second))
    print("PASS compiler-option change rebuilds both executables")

    run(command + ["clean"], env)
    assert not capture.exists() and not lab.exists() and not metadata.exists()
    print("PASS clean hook removes both executables and native build metadata")
print("Native build integration checks passed: 5 (local SDK fixtures only)")
