"""Local runtime tests. All installation tests use synthetic offline wheels.
No PyPI, AWS, credentials, auth or cloud provisioning is exercised.
"""
from __future__ import annotations
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import zipfile

APP = Path(__file__).resolve().parents[1]
SCRIPT = APP / 'priv/aws_setup/runtime.py'
spec = importlib.util.spec_from_file_location('ecai_aws_runtime', SCRIPT)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
VERSIONS = {'python':sys.version.split()[0], 'boto3':'1.43.18', 'botocore':'1.43.18'}


def wheel(directory, name, version, modules, requires=()):
    """Minimal, deliberately fake SDK fixtures for testing installer mechanics."""
    stem = f'{name}-{version}.dist-info'
    files = {**modules,
             f'{stem}/METADATA': f'Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n' + ''.join(f'Requires-Dist: {r}\n' for r in requires),
             f'{stem}/WHEEL':'Wheel-Version: 1.0\nGenerator: ecai-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n'}
    files = {key:value.encode() for key,value in files.items()}
    files[f'{stem}/RECORD'] = ('\n'.join(f'{key},sha256={base64.urlsafe_b64encode(hashlib.sha256(value).digest()).decode().rstrip("=")},{len(value)}' for key,value in files.items()) + f'\n{stem}/RECORD,,\n').encode()
    with zipfile.ZipFile(directory / f'{name}-{version}-py3-none-any.whl', 'w') as archive:
        for key,value in files.items(): archive.writestr(key,value)


def offline_wheels(directory):
    version=runtime.pins()[1]['boto3']
    wheel(directory,'botocore',version, {
        'botocore/__init__.py':f'__version__ = {version!r}\n',
        'botocore/config.py':'class Config: pass\n',
        'botocore/exceptions.py':'class ClientError(Exception): pass\n'})
    wheel(directory,'boto3',version, {'boto3/__init__.py':f'__version__ = {version!r}\n'}, [f'botocore == {version}'])


class RuntimeUnitTests(unittest.TestCase):
    def setUp(self):
        runtime.CANCEL.clear()
        self.temp = tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)/'runtime'
        self.events=[]
        self.emitter=patch.object(runtime,'emit',side_effect=lambda phase,**kw:self.events.append((phase,kw)))
        self.emitter.start()
    def tearDown(self):
        self.emitter.stop(); self.temp.cleanup(); runtime.CANCEL.clear()
    def settings(self, **kwargs):
        return {'mode':'managed','root':str(self.root),'install':True,'timeout_seconds':30,**kwargs}
    def mocked_build(self, settings=None):
        with patch.object(runtime,'run') as run, patch.object(runtime,'verify',return_value={'versions':VERSIONS}):
            result=runtime.ensure(settings or self.settings())
            return result,run.call_args_list
    def test_auto_creates_final_path_and_installs_only_wheels(self):
        result,calls=self.mocked_build()
        env=Path(result['python']).parent.parent
        self.assertEqual(env.parent,self.root)
        self.assertEqual(calls[0].args[0][-1],str(env))
        self.assertIn('--only-binary=:all:',calls[1].args[0])
        self.assertIn('--isolated',calls[1].args[0])
        self.assertIn('https://pypi.org/simple',calls[1].args[0])
        self.assertFalse(result['reused'])
        self.assertEqual(json.loads((self.root/'current.json').read_text())['environment'],env.name)
        self.assertEqual(self.root.stat().st_mode & 0o777,0o700)
    def test_reuses_without_creation_or_installation(self):
        first,_=self.mocked_build()
        second,calls=self.mocked_build()
        self.assertEqual(first['python'],second['python']); self.assertTrue(second['reused'])
        self.assertEqual(calls,[])
    def test_failed_health_rebuilds_without_mutating_existing(self):
        first,_=self.mocked_build()
        old=Path(first['python']).parent.parent
        (old/'sentinel').write_text('preserve')
        with patch.object(runtime,'run'), patch.object(runtime,'verify',side_effect=[runtime.Failure('dependency_check_failed'),{'versions':VERSIONS}]):
            second=runtime.ensure(self.settings())
        self.assertNotEqual(first['python'],second['python'])
        self.assertEqual((old/'sentinel').read_text(),'preserve')
    def test_failed_install_never_publishes_or_deletes_existing(self):
        first,_=self.mocked_build()
        previous=(self.root/'current.json').read_bytes()
        with patch.object(runtime,'verify',side_effect=runtime.Failure('dependency_check_failed')), patch.object(runtime,'run',side_effect=[b'',runtime.Failure('dependency_install_failed')]):
            with self.assertRaisesRegex(runtime.Failure,'dependency_install_failed'):
                runtime.ensure(self.settings())
        self.assertEqual((self.root/'current.json').read_bytes(),previous)
        self.assertEqual(len(list(self.root.glob('env-*'))),1)
        self.assertTrue(Path(first['python']).parent.parent.is_dir())
    def test_install_disabled_does_not_run_installer(self):
        with patch.object(runtime,'run') as run:
            with self.assertRaisesRegex(runtime.Failure,'automatic_install_disabled'):runtime.ensure(self.settings(install=False))
        run.assert_not_called()
    def test_external_path_is_check_only(self):
        with patch.object(runtime,'verify',return_value={'versions':VERSIONS}) as verify, patch.object(runtime,'run') as run:
            result=runtime.ensure({'mode':'external','python':'/approved/venv/bin/python','timeout_seconds':30})
        verify.assert_called_once(); run.assert_not_called(); self.assertEqual(result['mode'],'external')
        self.assertFalse(self.root.exists())
    def test_external_failure_is_not_automatically_repaired(self):
        with patch.object(runtime,'verify',side_effect=runtime.Failure('dependency_check_failed')), patch.object(runtime,'run') as run:
            with self.assertRaisesRegex(runtime.Failure,'dependency_check_failed'):
                runtime.ensure({'mode':'external','python':'/approved/venv/bin/python','timeout_seconds':30})
        run.assert_not_called()
    def test_unexpected_credentials_and_bad_parameters_rejected(self):
        for bad in [self.settings(credentials={}),self.settings(timeout_seconds=1),self.settings(timeout_seconds=True),self.settings(install='true'),{'mode':'external','python':'python3'}]:
            with self.subTest(bad=bad),self.assertRaises(runtime.Failure):runtime.ensure(bad)
    def test_managed_symlink_and_writable_root_rejected(self):
        target=Path(self.temp.name)/'target';target.mkdir()
        self.root.symlink_to(target,target_is_directory=True)
        with self.assertRaisesRegex(runtime.Failure,'unsafe_runtime_directory'):runtime.ensure(self.settings())
        self.root.unlink();self.root.mkdir();self.root.chmod(0o777)
        with self.assertRaisesRegex(runtime.Failure,'unsafe_runtime_directory'):runtime.ensure(self.settings())
    def test_lock_symlink_rejected(self):
        self.root.mkdir(mode=0o700)
        secret=Path(self.temp.name)/'unrelated';secret.write_text('keep')
        (self.root/'.lock').symlink_to(secret)
        with self.assertRaisesRegex(runtime.Failure,'runtime_directory_not_writable'):runtime.ensure(self.settings())
        self.assertEqual(secret.read_text(),'keep')
    def test_invalid_pointer_does_not_escape_root(self):
        self.mocked_build()
        p=self.root/'current.json';data=json.loads(p.read_text());data['environment']='../../unrelated';p.write_text(json.dumps(data))
        with self.assertRaisesRegex(runtime.Failure,'invalid_runtime_manifest'):runtime.ensure(self.settings())
    def test_wheelhouse_has_no_index_access(self):
        wheels=Path(self.temp.name)/'wheels';wheels.mkdir()
        _,calls=self.mocked_build(self.settings(wheelhouse=str(wheels)))
        command=calls[1].args[0]
        self.assertIn('--no-index',command);self.assertNotIn('--index-url',command)
    def test_environment_does_not_inherit_secrets_or_indexes(self):
        with patch.dict(os.environ, {'AWS_SECRET_ACCESS_KEY':'secret','PIP_EXTRA_INDEX_URL':'https://secret@example.test','HTTPS_PROXY':'proxy','PYTHONPATH':'bad'}):
            env=runtime.clean_env()
        self.assertNotIn('AWS_SECRET_ACCESS_KEY',env);self.assertNotIn('PIP_EXTRA_INDEX_URL',env)
        self.assertNotIn('HTTPS_PROXY',env);self.assertNotIn('PYTHONPATH',env)
        self.assertEqual(env['PIP_CONFIG_FILE'],os.devnull)
    def test_requirements_disallow_unpinned_or_executable_sources(self):
        req=Path(self.temp.name)/'requirements.txt'
        for bad in ('boto3>=1','--extra-index-url https://example.test\nboto3==1.43.18','-e .','boto3 @ https://example.test/a.whl'):
            req.write_text(bad)
            with patch.object(runtime,'REQUIREMENTS',req),self.assertRaisesRegex(runtime.Failure,'invalid_requirements'):runtime.pins()
    def test_cancellation_stops_child_process(self):
        pidfile=Path(self.temp.name)/'pid'
        task=[sys.executable,'-I','-S','-c',f'import os,time;open({str(pidfile)!r},"w").write(str(os.getpid()));time.sleep(60)']
        def cancel_after_start():
            deadline=time.monotonic()+3
            while not pidfile.exists() and time.monotonic()<deadline: time.sleep(.02)
            runtime.CANCEL.set()
        timer=threading.Thread(target=cancel_after_start,daemon=True);timer.start()
        try:
            with self.assertRaisesRegex(runtime.Failure,'runtime_cancelled'):runtime.run(task,time.monotonic()+5,'failed')
        finally:timer.join(timeout=4)
        pid=int(pidfile.read_text())
        with self.assertRaises(ProcessLookupError):os.kill(pid,0)
    def test_timeout_stops_child_process(self):
        with self.assertRaisesRegex(runtime.Failure,'runtime_timeout'):
            runtime.run([sys.executable,'-c','import time;time.sleep(60)'],time.monotonic()+.2,'failed')
    def test_lock_released_after_exception(self):
        with self.assertRaises(ValueError):
            with runtime.locked(self.root,time.monotonic()+2):raise ValueError()
        with runtime.locked(self.root,time.monotonic()+2):pass


class RuntimeSubprocessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.wheels=Path(cls.temp.name)/'wheels';cls.wheels.mkdir();offline_wheels(cls.wheels)
        cls.root=Path(cls.temp.name)/'envroot'
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    def spawn(self,root=None):
        p=subprocess.Popen([sys.executable,'-I','-u',str(SCRIPT)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        p.stdin.write(json.dumps({'mode':'managed','root':str(root or self.root),'install':True,'wheelhouse':str(self.wheels),'timeout_seconds':60})+'\n');p.stdin.flush()
        return p
    def collect(self,p):
        # Keep stdin open until the process exits; communicate(input) would send
        # EOF, which deliberately means cancellation for this private protocol.
        events=[json.loads(line) for line in p.stdout]
        code=p.wait(timeout=70);errors=p.stderr.read();p.stdin.close();p.stdout.close();p.stderr.close()
        self.assertEqual(code,0,errors+str(events));return events
    def test_real_offline_install_and_reuse_and_explicit_check(self):
        events=self.collect(self.spawn())
        self.assertEqual(events[-1]['phase'],'ready');self.assertFalse(events[-1]['reused'])
        self.assertIn('installing',[e['phase'] for e in events])
        envpython=events[-1]['python']
        again=self.collect(self.spawn())
        self.assertTrue(again[-1]['reused']);self.assertEqual(again[-1]['python'],envpython)
        self.assertNotIn('installing',[e['phase'] for e in again])
        with contextlib.redirect_stdout(io.StringIO()):
            result=runtime.ensure({'mode':'external','python':envpython,'timeout_seconds':30})
        self.assertEqual(result['versions']['boto3'],runtime.pins()[1]['boto3'])
    def test_cross_process_single_installer(self):
        root=Path(self.temp.name)/'concurrent'
        first=self.spawn(root);second=self.spawn(root)
        one=self.collect(first);two=self.collect(second)
        self.assertEqual(one[-1]['python'],two[-1]['python'])
        self.assertEqual(sum(not e[-1]['reused'] for e in (one,two)),1)
    def test_stdin_eof_cancels_without_publishing(self):
        root=Path(self.temp.name)/'cancelled'
        p=self.spawn(root);p.stdin.close()
        code=p.wait(timeout=10);events=p.stdout.read();errors=p.stderr.read();p.stdout.close();p.stderr.close()
        self.assertNotEqual(code,0,events)
        self.assertFalse((root/'current.json').exists())
        self.assertNotIn('Traceback',errors)


class RuntimeSourceContract(unittest.TestCase):
    def test_supervisor_gate_and_config(self):
        supervisor=(APP/'src/ecai_aws_setup_sup.erl').read_text()
        self.assertLess(supervisor.index('id => ecai_aws_setup_runtime'),supervisor.index('id => ecai_aws_setup_sessions_sup'))
        config=(APP/'src/ecai_aws_setup_config.erl').read_text()
        self.assertIn('python() -> ecai_aws_setup_runtime:python()',config)
        self.assertIn('<<"local_runtime">> => ecai_aws_setup_runtime:public()',config)
        session=(APP/'src/ecai_aws_setup_session.erl').read_text()
        self.assertIn('aws_runtime_not_ready',session)
    def test_no_request_driven_installer_or_cloud_credential_input(self):
        http=(APP/'src/ecai_aws_setup_http.erl').read_text()
        self.assertNotIn('runtime:recheck',http)
        self.assertNotIn('pip',http)
        script=SCRIPT.read_text()
        self.assertNotIn('boto3.Session(',script);self.assertNotIn('client(',script)
    def test_ui_polling_and_asset_revision(self):
        template=(APP/'priv/templates/ui/dashboard/compute_settings.mustache').read_text()
        script=(APP/'priv/static/js/ecai-aws-setup.js').read_text()
        shell=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        self.assertIn('id="awsSetupLocalRuntime"',template)
        self.assertIn('config?.local_runtime || session',script)
        self.assertIn('automatic-aws-v1-runtime-v1',shell)


if __name__=='__main__':unittest.main(verbosity=2)
