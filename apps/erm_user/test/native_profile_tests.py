#!/usr/bin/env python3
"""Exercise the real native Rebar profile without building native libraries."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[3]
EXTRACT_PROFILE = r'''
[Source, Target] = init:get_plain_arguments(),
{ok, Terms} = file:consult(Source),
Profile = proplists:get_value(erm, proplists:get_value(profiles, Terms)),
true = is_list(Profile),
Config = [{project_app_dirs, ["apps/*"]},
          {shell, proplists:get_value(shell, Terms)},
          {profiles, [{erm, Profile}]}],
ok = file:write_file(Target, [io_lib:format("~p.~n", [T]) || T <- Config]),
halt().
'''


class NativeProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.erl = os.environ.get("ERL") or shutil.which("erl")
        cls.rebar_executable = os.environ.get("REBAR3") or shutil.which("rebar3")
        if not cls.erl or not cls.rebar_executable:
            raise unittest.SkipTest("Erlang and Rebar3 are required")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="erm-native-profile-")
        self.root = Path(self.tmp.name)
        desktop = self.root / "desktop"
        desktop.mkdir(mode=0o700)
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith("ERM_USER_") or key in {
                "ERM_USERSPACE_BUILD", "ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS",
                "ERL_LIBS", "REBAR_CONFIG", "REBAR_PROFILE",
            }:
                self.env.pop(key, None)
        self.env.update({
            "HOME": str(desktop),
            "XDG_CONFIG_HOME": str(desktop / ".config"),
            "XDG_CACHE_HOME": str(desktop / ".cache"),
            "XDG_DATA_HOME": str(desktop / ".local/share"),
            "REBAR_GLOBAL_CONFIG_DIR": str(desktop / ".config/rebar3"),
            "REBAR_CACHE_DIR": str(desktop / ".cache/rebar3"),
            "REBAR_GLOBAL_CACHE_DIR": str(desktop / ".cache/rebar3"),
            "HEX_HOME": str(desktop / ".hex"),
        })
        extracted = subprocess.run(
            [self.erl, "-noshell", "-eval", EXTRACT_PROFILE, "-extra",
             str(PROJECT / "rebar.config"), str(self.root / "rebar.config")],
            env=self.env, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(extracted.returncode, 0, extracted.stdout + extracted.stderr)
        self.write("config/sys.config", '[{erm_user,[{profile_probe,damage}]}].\n')
        self.write("config/erm-user.sys.config", '[{erm_user,[{profile_probe,erm}]}].\n')
        self.write(
            "apps/damage/scripts/dev_shell.escript",
            '%% The inherited Damage script must not run.\n'
            'main(_) -> io:format("DAMAGE_SCRIPT_RAN~n",[]), erlang:halt(78).\n',
        )
        self.app("damage", "[kernel,stdlib]",
                 'io:format("DAMAGE_APP_RAN~n",[]), erlang:halt(79)')
        self.app("erm", "[kernel,stdlib,damage]", 'erlang:halt(80)')
        # Use the actual legacy resource, including its Damage dependency.
        shutil.copyfile(PROJECT / "apps/erm/src/erm.app.src",
                        self.root / "apps/erm/src/erm.app.src")
        self.app("erm_user", "[kernel,stdlib]",
                 'ok=application:load(erm), '
                 '{ok,spawn_link(fun()->receive stop->ok end end)}')

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def app(self, name, dependencies, start):
        self.write(f"apps/{name}/src/{name}.app.src",
                   f'{{application,{name},[{{vsn,"1.0"}},{{description,"fixture"}},'
                   f'{{registered,[]}},{{modules,[]}},{{applications,{dependencies}}},'
                   f'{{mod,{{{name}_app,[]}}}}]}}.\n')
        self.write(f"apps/{name}/src/{name}_app.erl",
                   f'-module({name}_app).\n-behaviour(application).\n'
                   '-export([start/2,stop/1]).\n'
                   f'start(_,_) -> {start}.\nstop(_)->ok.\n')

    def rebar(self, *args):
        # Keep stdin open until boot finishes; an immediate EOF can stop Eshell
        # before Rebar reaches application startup and produce a false success.
        proc = subprocess.Popen(
            [type(self).rebar_executable, *args], cwd=self.root, env=self.env,
            text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        try:
            proc.wait(timeout=30)
            output = proc.stdout.read()
            self.assertEqual(proc.returncode, 0, output)
            return output
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            proc.stdin.close()
            proc.stdout.close()

    def test_native_shell_selects_only_desktop_entry_and_configuration(self):
        expression = (
            'Apps=[A||{A,_,_}<-application:which_applications()],'
            'true=lists:member(erm_user,Apps),'
            'false=lists:member(erm,Apps),false=lists:member(damage,Apps),'
            '{ok,Deps}=application:get_key(erm,applications),'
            'true=lists:member(damage,Deps),'
            '{ok,erm}=application:get_env(erm_user,profile_probe),'
            'nonode@nohost=node(),'
            'io:format("NATIVE_PROFILE_PASS~n",[]),halt().'
        )
        output = self.rebar("as", "erm", "shell", "--eval", expression)
        self.assertIn("NATIVE_PROFILE_PASS", output)
        self.assertNotIn("DAMAGE_SCRIPT_RAN", output)
        self.assertNotIn("DAMAGE_APP_RAN", output)

    def test_native_compile_requires_no_helper_or_environment_flags(self):
        self.rebar("as", "erm", "compile")
        self.assertTrue((self.root / "_build/erm/lib/erm_user/ebin/erm_user.app").is_file())


if __name__ == "__main__":
    unittest.main()
