#!/usr/bin/env python3
"""DamageBDD-owned, unprivileged WebDriver provisioning (Python 3.10+ stdlib).

Invoked only by damage_webdriver_service through erlexec. No shell, sudo, curl
pipes, global npm install, or caller-supplied feature data. Provisioning publishes
runtime.json last. selection.json retains initially resolved versions and hashes.
"""
from __future__ import annotations
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import ssl
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

MAX_DOWNLOAD = 1024 * 1024 * 1024
MAX_EXTRACTED = 3 * 1024 * 1024 * 1024
MAX_MEMBERS = 100000
OFFICIAL = {'nodejs.org', 'googlechromelabs.github.io', 'storage.googleapis.com', 'dl.google.com'}
VERSION = re.compile(r'^\d+\.\d+\.\d+(?:\.\d+)?$')
ERRORS = {'unsafe_path', 'invalid_configuration', 'network_disabled', 'download_failed',
    'download_too_large', 'hash_mismatch', 'archive_invalid', 'platform_unsupported',
    'dependency_missing', 'dependency_command_failed', 'dependency_command_timeout',
    'runtime_not_installed', 'cache_integrity_failed', 'root_not_allowed',
    'android_licenses_not_accepted', 'doctor_failed', 'version_mismatch', 'install_locked'}

class ProvisionError(Exception):
    def __init__(self, code: str):
        if code not in ERRORS:
            code = 'invalid_configuration'
        super().__init__(code)
        self.code = code


def require(condition: bool, code='invalid_configuration') -> None:
    if not condition:
        raise ProvisionError(code)


def private_dir(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    for part in [*reversed(path.parents), path]:
        if part.is_symlink():
            raise ProvisionError('unsafe_path')
        if not part.exists():
            part.mkdir(mode=0o700)
        require(part.is_dir(), 'unsafe_path')
    require(path.stat().st_uid == os.geteuid(), 'unsafe_path')
    require(not (path.stat().st_mode & 0o022), 'unsafe_path')
    return path


def atomic_json(path: Path, value: dict) -> None:
    fd, tmp = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, sort_keys=True, separators=(',', ':'))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load_json(path: Path) -> dict:
    require(not path.is_symlink(), 'unsafe_path')
    require(path.stat().st_size <= 2 * 1024 * 1024, 'invalid_configuration')
    obj = json.loads(path.read_text(encoding='utf-8'))
    require(isinstance(obj, dict))
    return obj


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def config_id(req: dict) -> str:
    # Changing offline/bootstrap must reuse the same verified installation.
    stable = {k: v for k, v in req.items() if k not in ('offline', 'bootstrap')}
    return hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest()


def clean_env(home: Path, paths: list[str] | None = None, extra: dict | None = None) -> dict[str, str]:
    # Do not pass DAMAGE_SECRET_KEY, account credentials, SSH agent, npm tokens,
    # NODE_OPTIONS, Python hooks or arbitrary parent environment into children.
    env = {'HOME': str(home), 'PATH': os.pathsep.join((paths or []) + ['/usr/local/bin', '/usr/bin', '/bin']),
           'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'SHELL': '/bin/sh', 'CI': '1',
           'NO_COLOR': '1', 'npm_config_audit': 'false', 'npm_config_fund': 'false',
           'npm_config_engine_strict': 'true', 'APPIUM_SKIP_CHROMEDRIVER_INSTALL': '1'}
    env.update(extra or {})
    return env


def run(argv: list[str], env: dict, cwd: Path, timeout=120, input_data: bytes | None = None, *, stdout_only=False) -> str:
    require(bool(argv) and all(isinstance(a, str) and '\x00' not in a for a in argv))
    # A temp file bounds memory even when an installer prints a lot. erlexec
    # owns the whole process group, including this child's descendants.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as diagnostics:
        try:
            result = subprocess.run(argv, cwd=cwd, env=env, input=input_data,
                                    stdout=output, stderr=diagnostics if stdout_only else subprocess.STDOUT,
                                    timeout=timeout, check=False, shell=False)
        except subprocess.TimeoutExpired as exc:
            raise ProvisionError('dependency_command_timeout') from exc
        except OSError as exc:
            raise ProvisionError('dependency_missing') from exc
        output.seek(0, os.SEEK_END)
        size = output.tell()
        output.seek(max(0, size - 512 * 1024))
        text = output.read().decode('utf-8', errors='replace')
        if stdout_only:
            diagnostics.seek(0, os.SEEK_END)
            diagnostics.seek(max(0, diagnostics.tell() - 16000))
            warnings = diagnostics.read().decode('utf-8', errors='replace')
            if warnings:
                print(warnings, file=sys.stderr, flush=True)
        if result.returncode != 0:
            # Private managed logs only, not returned to BDD reports or HTTP clients.
            print(text[-16000:], file=sys.stderr, flush=True)
            raise ProvisionError('dependency_command_failed')
        return text.strip()


def run_json(argv: list[str], env: dict, cwd: Path, timeout=120):
    # Appium/npm diagnostics on stderr must not corrupt machine-readable stdout.
    text = run(argv, env, cwd, timeout, stdout_only=True)
    try:
        return json.loads(text)
    except (ValueError, TypeError) as exc:
        raise ProvisionError('dependency_command_failed') from exc


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, allowed: set[str]):
        self.allowed = allowed
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_url(newurl, self.allowed)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def validate_url(url: str, allowed: set[str]) -> None:
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme == 'https' and parsed.hostname in allowed and
            parsed.username is None and parsed.password is None and not parsed.fragment,
            'download_failed')


class Installer:
    def __init__(self, req: dict):
        require(req.get('schema') == 1)
        require(req.get('backend') in ('chromedriver', 'appium', 'fixture'))
        self.req = req
        self.root = private_dir(Path(req['root']))
        self.key = config_id(req)
        self.work = self.root / ('install-' + self.key[:24])
        self.selection_path = self.root / ('selection-' + self.key[:24] + '.json')
        self.selection = load_json(self.selection_path) if self.selection_path.exists() else {}
        self.inventory: dict[str, str] = {}
        self.network = req.get('bootstrap') is True and req.get('offline') is False
        self.home = private_dir(self.root / 'home')
        self.env = clean_env(self.home)
        self.env['npm_config_userconfig'] = str(self.root / 'npm-user.config')
        self.env['npm_config_globalconfig'] = str(self.root / 'npm-global.config')
        self.env['npm_config_cache'] = str(self.root / 'npm-cache')
        for config in ('npm-user.config', 'npm-global.config'):
            path = self.root / config
            require(not path.is_symlink(), 'unsafe_path')
            path.write_text('', encoding='utf-8')
            path.chmod(0o600)

    def save_selection(self) -> None:
        atomic_json(self.selection_path, self.selection)

    def read_url(self, url: str, maximum=8 * 1024 * 1024, allowed=OFFICIAL) -> bytes:
        require(self.network, 'network_disabled')
        validate_url(url, allowed)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            SafeRedirect(allowed), urllib.request.HTTPSHandler(context=ssl.create_default_context()))
        try:
            with opener.open(urllib.request.Request(url, headers={'User-Agent': 'DamageBDD-WebDriver/1'}), timeout=60) as response:
                result = response.read(maximum + 1)
                require(len(result) <= maximum, 'download_too_large')
                return result
        except ProvisionError:
            raise
        except Exception as exc:
            raise ProvisionError('download_failed') from exc

    def download(self, label: str, url: str, expected: str = '', allowed=OFFICIAL) -> Path:
        require(self.network, 'network_disabled')
        validate_url(url, allowed)
        previous = self.selection.get('artifacts', {}).get(label)
        if previous:
            require(previous['url'] == url, 'cache_integrity_failed')
            require(not expected or previous['sha256'] == expected.lower(), 'hash_mismatch')
            expected = previous['sha256']
        if expected:
            require(bool(re.fullmatch(r'[0-9a-fA-F]{64}', expected)))
        target = self.root / ('download-' + hashlib.sha256(url.encode()).hexdigest())
        if target.exists() and expected and not target.is_symlink() and digest(target) == expected.lower():
            return target
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), SafeRedirect(allowed),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()))
        fd, tmp = tempfile.mkstemp(prefix='.download-', dir=self.root)
        try:
            sha, total = hashlib.sha256(), 0
            with os.fdopen(fd, 'wb') as out:
                with opener.open(url, timeout=60) as response:
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        total += len(block)
                        require(total <= MAX_DOWNLOAD, 'download_too_large')
                        out.write(block)
                        sha.update(block)
                out.flush()
                os.fsync(out.fileno())
            actual = sha.hexdigest()
            require(not expected or actual == expected.lower(), 'hash_mismatch')
            os.replace(tmp, target)
            self.selection.setdefault('artifacts', {})[label] = {'url': url, 'sha256': actual}
            self.save_selection()
            return target
        except ProvisionError:
            raise
        except Exception as exc:
            raise ProvisionError('download_failed') from exc
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def remember(self, path: Path) -> str:
        require(path.is_file(), 'dependency_missing')
        # Hash through the path used in argv, so replacing a system symlink is
        # detected on reuse even when its former target still exists.
        self.inventory[str(path)] = digest(path)
        return str(path)

    def select(self, key: str, callback) -> str:
        if key not in self.selection:
            self.selection[key] = callback()
            self.save_selection()
        value = self.selection[key]
        require(isinstance(value, str) and VERSION.fullmatch(value) is not None)
        return value

    def install(self) -> dict:
        old = self.root / 'runtime.json'
        if old.exists():
            manifest = load_json(old)
            if manifest.get('config_id') == self.key:
                for filename, sha in manifest.get('inventory', {}).items():
                    require(Path(filename).is_file() and digest(Path(filename)) == sha, 'cache_integrity_failed')
                require(bool(manifest.get('inventory')), 'cache_integrity_failed')
                if manifest.get('backend') == 'appium':
                    manifest['chromedriver_autodownload'] = bool(self.req.get('chromedriver_autodownload')) and self.network
                    atomic_json(old, manifest)
                return manifest
        if self.req['backend'] == 'fixture':
            script = Path(self.req.get('script', ''))
            require(script.is_absolute() and script.is_file(), 'dependency_missing')
            result = {'script': self.remember(script), 'env': self.env}
        else:
            if self.req.get('source') != 'system':
                require(self.req.get('bootstrap') is True and not self.req.get('offline'), 'runtime_not_installed')
            # Incomplete builds never become an installed manifest. A retry cleans
            # only its private, configuration-addressed generation, under flock.
            require(not self.work.is_symlink(), 'unsafe_path')
            if self.work.exists():
                shutil.rmtree(self.work)
            self.work.mkdir(mode=0o700)
            print(f"Preparing managed {self.req['backend']} dependencies", flush=True)
            if self.req['backend'] == 'chromedriver':
                result = self.chrome()
            else:
                result = self.appium()
        result.update(schema=1, config_id=self.key, backend=self.req['backend'],
                      inventory=self.inventory, selected=self.selection,
                      installed_at=int(time.time()))
        atomic_json(old, result)
        return result

    def chrome(self) -> dict:
        if self.req.get('source') == 'system':
            driver = Path(self.req.get('executable', ''))
            browser = Path(self.req.get('browser', ''))
            require(driver.is_absolute() and browser.is_absolute(), 'dependency_missing')
        else:
            target = cft_platform()
            requested = self.req.get('version', 'stable')
            def select_version():
                if requested != 'stable':
                    require(VERSION.fullmatch(requested) is not None)
                    return requested
                data = json.loads(self.read_url('https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json'))
                return data['channels']['Stable']['version']
            version = self.select('chrome_version', select_version)
            for product, field in (('chrome', 'chrome_sha256'), ('chromedriver', 'driver_sha256')):
                url = f'https://storage.googleapis.com/chrome-for-testing-public/{version}/{target}/{product}-{target}.zip'
                archive = self.download(product, url, self.req.get(field, ''))
                extract(archive, self.work / product, 'zip')
            driver = self.work / 'chromedriver' / f'chromedriver-{target}' / 'chromedriver'
            browser = self.work / 'chrome' / f'chrome-{target}'
            browser = browser / ('chrome' if target == 'linux64' else 'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing')
        require(driver.is_file() and browser.is_file(), 'dependency_missing')
        # All downloaded executable permissions are sanitized by extract().
        dv = run([str(driver), '--version'], self.env, self.root)
        bv = run([str(browser), '--version'], self.env, self.root)
        a, b = re.search(r'\d+\.\d+\.\d+\.\d+', dv), re.search(r'\d+\.\d+\.\d+\.\d+', bv)
        require(a is not None and b is not None, 'version_mismatch')
        require(a[0].split('.')[:3] == b[0].split('.')[:3], 'version_mismatch')
        return {'chromedriver': self.remember(driver), 'chrome': self.remember(browser),
                'version': a[0], 'env': self.env}

    def node(self) -> tuple[str, str]:
        config = self.req.get('node', {})
        if config.get('source', 'download') == 'system':
            node = Path(config.get('executable', '/usr/bin/node'))
            require(node.is_absolute() and node.is_file(), 'dependency_missing')
            npm = node.parent / 'npm'
            require(npm.is_file(), 'dependency_missing')
        else:
            requested = config.get('version', 'lts')
            def select_version():
                if requested != 'lts':
                    require(VERSION.fullmatch(requested) is not None)
                    return requested
                choices = json.loads(self.read_url('https://nodejs.org/dist/index.json'))
                return next(v['version'].removeprefix('v') for v in choices if v.get('lts') and
                            int(v['version'][1:].split('.')[0]) >= 22)
            version = self.select('node_version', select_version)
            target = node_platform()
            filename = f'node-v{version}-{target}.tar.gz'
            base = f'https://nodejs.org/dist/v{version}/'
            sums = self.read_url(base + 'SHASUMS256.txt').decode()
            upstream = next((line.split()[0] for line in sums.splitlines() if line.split()[-1] == filename), '')
            require(bool(upstream), 'hash_mismatch')
            configured = config.get('sha256', '')
            require(not configured or configured.lower() == upstream, 'hash_mismatch')
            archive = self.download('node', base + filename, upstream)
            extract(archive, self.work / 'node', 'tar')
            bindir = self.work / 'node' / f'node-v{version}-{target}' / 'bin'
            node, npm = bindir / 'node', bindir / 'npm'
        self.env['PATH'] = str(node.parent) + os.pathsep + self.env['PATH']
        nv = run([str(node), '--version'], self.env, self.root).removeprefix('v')
        numbers = tuple(int(v) for v in nv.split('.'))
        require((numbers[0] == 20 and numbers >= (20,19,0)) or
                (numbers[0] == 22 and numbers >= (22,12,0)) or numbers[0] >= 24, 'version_mismatch')
        require(int(run([str(npm), '--version'], self.env, self.root).split('.')[0]) >= 10, 'version_mismatch')
        self.remember(node)
        self.remember(npm)
        return str(node), str(npm)

    def java(self) -> None:
        cfg = self.req.get('java', {})
        if not cfg:
            return
        if cfg.get('source', 'system') == 'system':
            home = Path(cfg.get('home', ''))
            require(home.is_absolute(), 'dependency_missing')
        else:
            require(cfg.get('source') == 'archive' and bool(cfg.get('sha256')))
            url = cfg.get('url', '')
            host = urllib.parse.urlsplit(url).hostname
            archive = self.download('java', url, cfg['sha256'], {host})
            destination = self.work / 'java'
            extract(archive, destination, 'zip' if url.endswith('.zip') else 'tar')
            home = destination / cfg.get('subdir', '')
            require(home.resolve().is_relative_to(destination.resolve()), 'unsafe_path')
        binary = home / 'bin/java'
        self.remember(binary)
        self.env['JAVA_HOME'] = str(home)
        self.env['PATH'] = str(home / 'bin') + os.pathsep + self.env['PATH']
        run([str(binary), '-version'], self.env, self.root)

    def android(self) -> None:
        cfg = self.req.get('android', {})
        if not cfg.get('enabled', False):
            return
        require(isinstance(cfg.get('accept_licenses', False), bool))
        if cfg.get('source', 'system') == 'system':
            home = Path(cfg.get('home', ''))
            require(home.is_absolute() and home.is_dir(), 'dependency_missing')
            require(not cfg.get('packages'), 'invalid_configuration')
        else:
            require(cfg.get('source') == 'download' and bool(cfg.get('sha256')))
            require(cfg.get('accept_licenses') is True, 'android_licenses_not_accepted')
            home = self.work / 'android-sdk'
            archive = self.download('android-command-tools', cfg.get('command_tools_url', ''), cfg['sha256'], {'dl.google.com'})
            temporary = self.work / 'android-command-tools'
            extract(archive, temporary, 'zip')
            (home / 'cmdline-tools').mkdir(parents=True, mode=0o700)
            shutil.move(str(temporary / 'cmdline-tools'), home / 'cmdline-tools/latest')
            sdkmanager = home / 'cmdline-tools/latest/bin/sdkmanager'
            packages = cfg.get('packages', ['platform-tools'])
            require(isinstance(packages, list) and all(isinstance(p, str) and
                re.fullmatch(r'[A-Za-z0-9_.;-]+', p) and not p.startswith('-') for p in packages))
            require('platform-tools' in packages)
            self.env['ANDROID_HOME'] = str(home)
            self.env['ANDROID_SDK_ROOT'] = str(home)
            run([str(sdkmanager), '--sdk_root=' + str(home), '--licenses'], self.env,
                self.root, 300, input_data=b'y\n' * 200)
            run([str(sdkmanager), '--sdk_root=' + str(home), *packages], self.env,
                self.root, 1200, input_data=b'y\n' * 200)
        self.env['ANDROID_HOME'] = str(home)
        self.env['ANDROID_SDK_ROOT'] = str(home)
        self.env['PATH'] = str(home / 'platform-tools') + os.pathsep + self.env['PATH']
        self.remember(home / 'platform-tools/adb')

    def appium(self) -> dict:
        # Private Appium installs require npm. For fully offline/system mode use
        # preinstalled Node+Appium and an explicitly owned APPIUM_HOME cache.
        node, npm = self.node()
        self.java()
        self.android()
        drivers = self.req.get('drivers', {})
        require(isinstance(drivers, dict))
        if 'xcuitest' in drivers:
            require(sys.platform == 'darwin', 'platform_unsupported')
            run(['/usr/bin/xcode-select', '-p'], self.env, self.root)
        if self.req.get('source') == 'system':
            appium = self.req.get('executable', '')
            require(os.path.isabs(appium) and Path(appium).is_file(), 'dependency_missing')
            require(not drivers, 'invalid_configuration')
            # A system Appium may discover drivers installed under this private
            # home. Existing external home directories are never modified.
            prefix = [appium]
        else:
            requested = self.req.get('version', 'latest')
            def select_appium():
                if requested != 'latest':
                    require(VERSION.fullmatch(requested) is not None)
                    return requested
                return run_json([npm, 'view', 'appium@latest', 'version', '--json'], self.env, self.root)
            version = self.select('appium_version', select_appium)
            require(int(version.split('.')[0]) == 3, 'version_mismatch')
            package = self.work / 'appium'
            package.mkdir(mode=0o700)
            atomic_json(package / 'package.json', {'name': 'damage-webdriver-runtime', 'private': True,
                'version': '1.0.0', 'dependencies': {'appium': version}})
            # Persist the resolved dependency lock outside an incomplete generation
            # and use npm ci on retries. --ignore-scripts prevents install hooks;
            # required device binaries are provisioned explicitly by the drivers.
            lock = self.root / ('npm-lock-' + self.key[:24] + '.json')
            if lock.exists():
                shutil.copyfile(lock, package / 'package-lock.json')
            else:
                run([npm, 'install', '--package-lock-only', '--ignore-scripts', '--no-audit', '--no-fund'],
                    self.env, package, 300)
                atomic_json(lock, json.loads((package / 'package-lock.json').read_text()))
            run([npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], self.env, package, 600)
            prefix = [node, str(package / 'node_modules/appium/index.js')]
        appium_home = private_dir(self.root / ('appium-home-' + self.key[:24]))
        self.env['APPIUM_HOME'] = str(appium_home)
        for driver, requested in sorted(drivers.items()):
            require(driver in ('uiautomator2', 'xcuitest'))
            pkg = f'appium-{driver}-driver'
            def select_driver(pkg=pkg, requested=requested):
                if requested != 'latest':
                    require(VERSION.fullmatch(requested) is not None)
                    return requested
                return run_json([npm, 'view', pkg + '@latest', 'version', '--json'], self.env, self.root)
            version = self.select(driver + '_version', select_driver)
            installed = run_json(prefix + ['driver', 'list', '--installed', '--json'], self.env, self.root)
            existing = installed.get(driver)
            if existing:
                require(existing.get('version') == version, 'version_mismatch')
            else:
                require(self.network, 'network_disabled')
                run(prefix + ['driver', 'install', f'{driver}@{version}'], self.env, self.root, 600)
            if self.req.get('doctor', True):
                output = run(prefix + ['driver', 'doctor', driver], self.env, self.root, 180)
                # Doctor can emit diagnostics yet return zero. Fail closed unless
                # it explicitly reports no REQUIRED fixes; optional fixes are fine.
                require('0 required fixes needed' in output.lower(), 'doctor_failed')
        actual = run(prefix + ['--version'], self.env, self.root)
        require(bool(re.search(r'\b3\.\d+\.\d+\b', actual)), 'version_mismatch')
        for part in prefix:
            self.remember(Path(part))
        driver_dir = private_dir(self.root / 'android-chromedrivers')
        driver_binary = self.req.get('android_chromedriver', '')
        if driver_binary:
            require(os.path.isabs(driver_binary), 'invalid_configuration')
            self.remember(Path(driver_binary))
        autodownload = self.req.get('chromedriver_autodownload', False)
        require(isinstance(autodownload, bool))
        # Offline mode also removes the runtime's scoped Appium download feature.
        return {'argv': prefix, 'env': self.env, 'appium_home': str(appium_home),
                'chromedriver_dir': str(driver_dir), 'android_chromedriver': driver_binary,
                'chromedriver_autodownload': autodownload and self.network}


def cft_platform(system: str | None = None, machine: str | None = None) -> str:
    system, machine = system or platform.system(), machine or platform.machine()
    values = {('Linux','x86_64'): 'linux64', ('Darwin','x86_64'): 'mac-x64',
              ('Darwin','arm64'): 'mac-arm64', ('Darwin','aarch64'): 'mac-arm64'}
    require((system, machine) in values, 'platform_unsupported')
    return values[(system, machine)]


def node_platform() -> str:
    machine = {'x86_64': 'x64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine())
    system = {'Linux': 'linux', 'Darwin': 'darwin'}.get(platform.system())
    require(machine is not None and system is not None, 'platform_unsupported')
    return f'{system}-{machine}'


def safe_member(name: str, destination: Path) -> Path:
    pure = PurePosixPath(name)
    require(not pure.is_absolute() and '..' not in pure.parts and '\\' not in name
            and '\x00' not in name and bool(pure.parts), 'archive_invalid')
    target = destination.joinpath(*pure.parts)
    require(target.resolve().is_relative_to(destination.resolve()), 'archive_invalid')
    return target


def extract(archive: Path, destination: Path, kind: str) -> None:
    """No extractall: validate paths, links, types, duplicate names and size limits."""
    require(not destination.exists(), 'archive_invalid')
    destination.mkdir(parents=True, mode=0o700)
    seen, links, total = set(), [], 0
    try:
        manager = zipfile.ZipFile(archive) if kind == 'zip' else tarfile.open(archive, 'r:*')
        with manager as source:
            for index, member in enumerate(source.infolist() if kind == 'zip' else source):
                require(index < MAX_MEMBERS, 'archive_invalid')
                name = member.filename if kind == 'zip' else member.name
                path = safe_member(name, destination)
                require(path not in seen, 'archive_invalid')
                seen.add(path)
                size = member.file_size if kind == 'zip' else member.size
                total += size
                require(total <= MAX_EXTRACTED, 'archive_invalid')
                mode = (member.external_attr >> 16) if kind == 'zip' else member.mode
                isdir = member.is_dir() if kind == 'zip' else member.isdir()
                islink = stat.S_ISLNK(mode) if kind == 'zip' else member.issym()
                if isdir:
                    path.mkdir(parents=True, exist_ok=True, mode=0o700)
                    continue
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                if islink:
                    require(size <= 4096, 'archive_invalid')
                    link = source.read(member).decode('utf-8') if kind == 'zip' else member.linkname
                    require(not os.path.isabs(link) and '\\' not in link, 'archive_invalid')
                    links.append((path, link))
                    continue
                if kind == 'tar':
                    require(member.isfile(), 'archive_invalid')
                else:
                    require(stat.S_IFMT(mode) in (0, stat.S_IFREG), 'archive_invalid')
                reader = source.open(member) if kind == 'zip' else source.extractfile(member)
                require(reader is not None, 'archive_invalid')
                with reader, path.open('xb') as out:
                    shutil.copyfileobj(reader, out, length=1024 * 1024)
                path.chmod(0o755 if mode & 0o111 else 0o644)
            # Links are created after regular files, never used as write paths.
            for path, target in links:
                require(not path.exists() and not path.is_symlink(), 'archive_invalid')
                require((path.parent / target).resolve().is_relative_to(destination.resolve()), 'archive_invalid')
                path.symlink_to(target)
            for path, _ in links:
                require(path.resolve().is_relative_to(destination.resolve()), 'archive_invalid')
    except ProvisionError:
        raise
    except Exception as exc:
        raise ProvisionError('archive_invalid') from exc


@contextlib.contextmanager
def lock(root: Path):
    path = root / '.install.lock'
    require(not path.is_symlink(), 'unsafe_path')
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ProvisionError('install_locked') from exc
        yield
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', required=True, type=Path)
    args = parser.parse_args()
    root = None
    try:
        require(os.geteuid() != 0, 'root_not_allowed')
        req = load_json(args.request)
        root = private_dir(Path(req['root']))
        with lock(root):
            Installer(req).install()
        return 0
    except ProvisionError as exc:
        print('WebDriver provisioning failed: ' + exc.code, file=sys.stderr)
        if root is not None:
            atomic_json(root / 'error.json', {'code': exc.code})
        return 1
    except Exception:
        print('WebDriver provisioning failed: invalid_configuration', file=sys.stderr)
        if root is not None:
            atomic_json(root / 'error.json', {'code': 'invalid_configuration'})
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
