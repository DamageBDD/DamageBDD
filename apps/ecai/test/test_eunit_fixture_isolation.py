"""Source-layout and shell-staging checks. These do NOT execute Erlang/EUnit.

The shell checks use explicit fake erl/erlc executables in a private directory;
this tests staging, argument construction, and cleanup, never Erlang behavior.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

APP = Path(__file__).resolve().parents[1]
MODULE = re.compile(r"^\s*-module\s*\(\s*([a-z][a-zA-Z0-9_]*)\s*\)\s*\.", re.M)
HARNESSES = {
    "personalities/chat": {
        "ecai", "ecai_ollama_rag", "ecai_personalities", "poolboy",
        "damage_gun", "ecai_chat_personality_tests",
    },
    "personalities/cln": {"damage_cln", "ecai_personality_cln_tests"},
    "conversation_personalities": {
        "cowboy_req", "damage_auth", "ecai_chat", "ecai_personalities",
        "trails", "ecai_conversation_personalities_tests",
    },
}
DEPENDENCY_DOUBLES = {"cowboy_req", "damage_auth", "damage_cln", "damage_gun", "poolboy", "trails"}
FAKE_TOOL = r'''
import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
tool = pathlib.Path(sys.argv[0]).name
entry = {"tool": tool, "args": args}
if tool == "erlc":
    out = pathlib.Path(args[args.index("-o") + 1])
    assert out.is_dir(), out
    sources = []
    for arg in args:
        if arg.endswith(".erl"):
            path = pathlib.Path(arg)
            assert path.is_file(), path
            sources.append({"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    assert sources, args
    entry.update(out=str(out), sources=sources)
with open(os.environ["ECAI_FIXTURE_TOOL_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(entry) + "\n")
sys.exit(int(os.environ.get("ECAI_FIXTURE_" + tool.upper() + "_EXIT", "0")))
'''


def module_name(path: Path) -> str:
    match = MODULE.search(path.read_text(encoding="utf-8"))
    if match is None:
        raise AssertionError(f"No module declaration: {path}")
    return match.group(1)


class EUnitFixtureIsolationTests(unittest.TestCase):
    def test_automatic_sources_do_not_declare_duplicate_modules(self):
        declarations: dict[str, list[str]] = {}
        for directory in (APP / "src", APP / "test"):
            for path in sorted(directory.rglob("*.erl")):
                declarations.setdefault(module_name(path), []).append(str(path.relative_to(APP)))
        duplicates = {name: paths for name, paths in declarations.items() if len(paths) > 1}
        self.assertEqual({}, duplicates, f"Auto-compiled module collisions: {duplicates}")

    def test_dependency_doubles_are_not_automatic_test_sources(self):
        doubles = [str(path.relative_to(APP)) for path in (APP / "test").rglob("*.erl")
                   if module_name(path) in DEPENDENCY_DOUBLES]
        self.assertEqual([], sorted(doubles))

    def test_isolated_harnesses_have_no_automatic_erlang_sources(self):
        for relative in HARNESSES:
            with self.subTest(harness=relative):
                self.assertEqual([], list((APP / "test" / relative).rglob("*.erl")))

    def test_fixture_names_and_drivers_are_preserved(self):
        for relative, expected in HARNESSES.items():
            with self.subTest(harness=relative):
                fixtures = list((APP / "test" / relative).rglob("*.erl.fixture"))
                self.assertEqual(expected, {module_name(path) for path in fixtures})
                self.assertEqual(len(expected), len(fixtures))
                for path in fixtures:
                    self.assertEqual(module_name(path) + ".erl.fixture", path.name)

    def test_rag_production_export_and_implementation_remain_present(self):
        text = (APP / "src/ecai_ollama_rag.erl").read_text(encoding="utf-8")
        self.assertRegex(text, r"(?s)-export\(\[.*?retrieve_sources_lexical/3.*?\]\)")
        self.assertRegex(text, r"(?m)^retrieve_sources_lexical\(")

    def test_isolated_runners_stage_byte_identical_sources(self):
        for relative in HARNESSES:
            with self.subTest(harness=relative):
                self.check_runner(relative)

    def test_isolated_runners_cleanup_on_compiler_failure(self):
        for relative in HARNESSES:
            with self.subTest(harness=relative):
                self.check_runner(relative, compiler_exit=23)

    def test_isolated_runners_cleanup_on_vm_failure(self):
        for relative in HARNESSES:
            with self.subTest(harness=relative):
                self.check_runner(relative, vm_exit=24)

    def check_runner(self, relative: str, compiler_exit: int = 0, vm_exit: int = 0) -> None:
        harness = APP / "test" / relative
        fixtures = list(harness.rglob("*.erl.fixture"))
        self.assertTrue(fixtures, f"Missing .erl.fixture inputs in {harness}")
        with tempfile.TemporaryDirectory(prefix="ecai-fixture-shell-check-") as temp:
            work = Path(temp)
            fakebin = work / "bin"
            scratch = work / "tmp"
            jsx = work / "jsx"
            for directory in (fakebin, scratch, jsx):
                directory.mkdir()
            # A placeholder solely for the shell's JSX preflight; never loaded.
            (jsx / "jsx.beam").write_bytes(b"shell-preflight-placeholder")
            for name in ("erl", "erlc"):
                tool = fakebin / name
                tool.write_text(f"#!{sys.executable}\n" + FAKE_TOOL, encoding="utf-8")
                tool.chmod(0o700)
            log = work / "calls.jsonl"
            env = os.environ.copy()
            env.update({
                "PATH": str(fakebin) + os.pathsep + env.get("PATH", ""),
                "TMPDIR": str(scratch), "JSX_EBIN": str(jsx), "ECAI_JSX_EBIN": str(jsx),
                "ECAI_ERL": str(fakebin / "erl"), "ECAI_ERLC": str(fakebin / "erlc"),
                "ECAI_FIXTURE_TOOL_LOG": str(log),
                "ECAI_FIXTURE_ERLC_EXIT": str(compiler_exit),
                "ECAI_FIXTURE_ERL_EXIT": str(vm_exit),
            })
            result = subprocess.run(["bash", str(harness / "run.sh")], cwd=work,
                                    env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(compiler_exit or vm_exit, result.returncode, result.stdout + result.stderr)
            calls = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(["erlc"] if compiler_exit else ["erlc", "erl"],
                             [entry["tool"] for entry in calls])
            compile_call = calls[0]
            out = Path(compile_call["out"])
            self.assertEqual(scratch, out.parent)
            expected = {path.name.removesuffix(".fixture"): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in fixtures}
            staged = {Path(item["path"]).name: item["sha256"]
                      for item in compile_call["sources"]
                      if Path(item["path"]).is_relative_to(out)}
            self.assertEqual(expected, staged)
            for item in compile_call["sources"]:
                self.assertFalse(Path(item["path"]).is_relative_to(harness), item)
            if not compiler_exit:
                self.assertIn(str(out), calls[1]["args"])
            self.assertFalse(out.exists(), "EXIT trap left temporary source/beam directory behind")
            self.assertEqual([], list(scratch.iterdir()))


if __name__ == "__main__":
    unittest.main()
