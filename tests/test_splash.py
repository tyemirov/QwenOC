from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import test_backends

MODEL = 'incoai/Qwen3.8-27B-Splash'
REQUEST_LOG = 'Done · input 556 · output 110 · 13.5 tok/s'
REQUEST_ERROR = 'Splash request diagnostic on stderr'


class SplashHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == '/ready' and getattr(self.server, 'unrelated_service', False):
            self.send_error(404)
            return
        if self.path == '/ready':
            payload = {'status': 'ready'}
        elif self.path == '/v1/models':
            payload = {'data': [{'id': self.server.model}]}
        elif self.path == '/status':
            payload = {'ready': True, 'maximum_context_tokens': self.server.context,
                       'instance': {'model': self.server.model}}
        elif self.path == '/test-request':
            print(REQUEST_LOG, flush=True)
            print(REQUEST_ERROR, file=sys.stderr, flush=True)
            payload = {'status': 'complete'}
        else:
            self.send_error(404)
            return
        if self.path != '/ready' and self.server.api_key and self.headers.get('Authorization') != 'Bearer ' + self.server.api_key:
            self.send_error(401)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())


def start_server(port=0, model=MODEL, context=65536, api_key=''):
    server = ThreadingHTTPServer(('127.0.0.1', port), SplashHandler)
    server.model, server.context, server.api_key = model, context, api_key
    return server


class TestSplash:
    def setup_method(self):
        self.harness = test_backends.BackendLaunchTests()
        self.harness.setUp()
        self.harness.environment['TEST_LOCAL_ALLOWED'] = '1'
        self.harness.environment.pop('SPLASH_API_KEY', None)
        self.server = start_server()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.harness.environment['TEST_CURL_BIN'] = shutil.which('curl')
        self.harness.environment.pop('SPLASH_PORT', None)
        self.harness.environment['TEST_SPLASH_PORT'] = str(self.server.server_port)
        with self.harness.shell_environment.open('a') as script:
            script.write('curl() { local arg; local args=(); for arg in "$@"; do case "$arg" in http://127.0.0.1:8000/*) arg="http://127.0.0.1:$TEST_SPLASH_PORT/${arg#http://127.0.0.1:8000/}" ;; esac; args+=("$arg"); done; "$TEST_CURL_BIN" "${args[@]}"; }\nexport -f curl\n')
            script.write(f'splash() {{ exec "{sys.executable}" "{Path(__file__).resolve()}" --serve "$@"; }}\nexport -f splash\n')
        self.harness.environment['TEST_SPLASH_LIFECYCLE'] = str(self.harness.directory / 'lifecycle')

    def teardown_method(self):
        self.server.shutdown()
        self.server.server_close()
        self.harness.doCleanups()

    def test_launcher_uses_splash_context_and_reasoning(self):
        result = self.harness.invoke('--backend', 'splash', str(self.harness.target))
        assert result.returncode == 0, result.stderr
        record = self.harness.record()
        config = record['config']
        assert config['model'] == config['small_model'] == 'splash/' + MODEL
        assert config['enabled_providers'] == ['splash']
        assert list(config['provider']) == ['splash']
        provider = config['provider']['splash']
        assert provider['options']['baseURL'] == 'http://127.0.0.1:8000/v1'
        model = provider['models'][MODEL]
        assert model['limit'] == {'context': 65536, 'input': 49152, 'output': 16384}
        assert model['variants']['xhigh'] == {'reasoningEffort': 'xhigh'}
        assert model['options'] == {'reasoningEffort': 'medium'}
        assert config['agent']['qwen-local']['model'] == 'splash/' + MODEL
        assert config['compaction']['reserved'] == 16384
        assert record['arguments'][1:5] == ['--model', 'splash/' + MODEL, '--agent', 'qwen-local']
        assert not self.harness.calls_for('lms')
        assert not Path(self.harness.environment['TEST_SPLASH_LIFECYCLE']).exists()

    def test_wrong_model_is_rejected(self):
        self.server.model = 'incoai/Qwen3.6-35B-A3B-Splash'
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode != 0
        assert MODEL in result.stderr
        assert not self.harness.record_path.exists()

    def test_invalid_context_is_rejected(self):
        self.server.context = '65536'
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode != 0
        assert not self.harness.record_path.exists()

    def test_api_key_authentication(self):
        self.server.api_key = 'splash-test-key'
        self.harness.environment['SPLASH_API_KEY'] = self.server.api_key
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode == 0, result.stderr
        assert 'splash-test-key' not in result.stdout + result.stderr
        assert self.harness.record()['config']['provider']['splash']['options']['apiKey'] == '{env:SPLASH_API_KEY}'

    def test_wrong_api_key_does_not_start_another_server(self):
        self.server.api_key = 'required-key'
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode != 0
        assert not Path(self.harness.environment['TEST_SPLASH_LIFECYCLE']).exists()

    def test_doctor_uses_live_splash_without_lm_studio(self):
        result = self.harness.invoke('--backend=splash', '--require-live', str(self.harness.target), command='doctor.command')
        assert result.returncode == 0, result.stderr
        assert 'Splash' in result.stdout
        assert not self.harness.calls_for('lms')

    def test_doctor_offline_is_read_only(self):
        self.server.shutdown()
        self.server.server_close()
        result = self.harness.invoke('--backend=splash', command='doctor.command')
        assert result.returncode == 0, result.stderr
        assert 'live checks skipped' in result.stdout
        assert not Path(self.harness.environment['TEST_SPLASH_LIFECYCLE']).exists()
        result = self.harness.invoke('--backend=splash', '--require-live', command='doctor.command')
        assert result.returncode != 0
        assert not Path(self.harness.environment['TEST_SPLASH_LIFECYCLE']).exists()

    def test_installer_and_alias_use_splash(self):
        result = self.harness.invoke('--backend=splash', command='install.command')
        assert result.returncode == 0, result.stderr
        assert not self.harness.calls_for('lms')
        result = self.harness.invoke('--backend=splash', str(self.harness.target), command='launch-opencode.command')
        assert result.returncode == 0, result.stderr
        assert self.harness.record()['config']['model'] == 'splash/' + MODEL

    def test_owned_server_startup_failure_is_reported(self):
        self.server.shutdown()
        self.server.server_close()
        with self.harness.shell_environment.open('a') as script:
            script.write('splash() { printf "resource_assembly: insufficient memory\\n" >&2; return 9; }\nexport -f splash\n')
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode == 5, result.stderr
        assert 'stopped before readiness' in result.stderr
        assert 'resource_assembly: insufficient memory' in result.stderr
        logs = list((Path(self.harness.environment['HOME']) / 'Library/Logs/QwenOC').glob('splash.*'))
        assert len(logs) == 1
        assert 'resource_assembly: insufficient memory' in logs[0].read_text()
        assert not self.harness.record_path.exists()
        assert not (self.harness.directory / 'opencode-qwen3.8-27b.lock').exists()

    def test_owned_server_logs_do_not_reach_opencode_terminal(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        with self.harness.shell_environment.open('a') as script:
            script.write(f'opencode() {{ if [[ "$1" != "--version" ]]; then curl -fsS http://127.0.0.1:8000/test-request >/dev/null || return; fi; "{sys.executable}" "$TEST_HELPER" opencode "$@"; }}\nexport -f opencode\n')
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode == 0, result.stderr
        assert self.harness.record_path.exists()
        assert REQUEST_LOG not in result.stdout + result.stderr
        assert REQUEST_ERROR not in result.stdout + result.stderr
        logs = list((Path(self.harness.environment['HOME']) / 'Library/Logs/QwenOC').glob('splash.*'))
        assert len(logs) == 1
        assert str(logs[0]) in result.stdout
        assert REQUEST_LOG in logs[0].read_text()
        assert REQUEST_ERROR in logs[0].read_text()

    def test_model_override_is_rejected(self):
        result = self.harness.invoke('--backend=splash', str(self.harness.target), '--', '--model', 'another/model')
        assert result.returncode == 2, result.stderr
        assert not self.harness.record_path.exists()

    def test_local_session_lock_is_respected(self):
        lock = self.harness.directory / 'opencode-qwen3.8-27b.lock'
        lock.mkdir()
        (lock / 'pid').write_text(str(os.getpid()))
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode == 7, result.stderr
        assert (lock / 'pid').read_text() == str(os.getpid())
        assert not self.harness.record_path.exists()

    def test_bureaucrat_preserves_workspace_tools(self):
        home = Path(self.harness.environment['HOME'])
        gmail = home / '.gmail-mcp'
        drive = home / '.config/google-drive-mcp'
        gmail.mkdir(parents=True)
        drive.mkdir(parents=True)
        (gmail / 'gcp-oauth.keys.json').write_text('{"installed": {}}')
        (gmail / 'credentials.json').write_text('{"scopes": ["gmail.modify"]}')
        scopes = ['openid', 'https://www.googleapis.com/auth/userinfo.email']
        scopes += ['https://www.googleapis.com/auth/' + scope for scope in ['drive', 'documents', 'spreadsheets']]
        (drive / 'tokens.json').write_text(json.dumps({'version': 2, 'accounts': {'test': {'scope': ' '.join(scopes)}}}))
        chrome_app = self.harness.directory / 'Chrome.app'
        chrome_bin = chrome_app / 'Contents/MacOS/Google Chrome'
        chrome_bin.parent.mkdir(parents=True)
        chrome_bin.symlink_to('/usr/bin/true')
        chrome_data = home / 'Library/Application Support/Google/Chrome'
        chrome_data.mkdir(parents=True)
        (chrome_data / 'DevToolsActivePort').write_text('9222\n/devtools/browser/test\n')
        with self.harness.shell_environment.open('a') as script:
            script.write(f'osascript() {{ printf "%s\\n" "{chrome_app}/"; }}\nexport -f osascript\n')
            script.write("awk() { if [[ \"$1\" == '{print $NF}' ]]; then printf '144.0.0\\n'; else command awk \"$@\"; fi; }\nexport -f awk\n")
            script.write('pgrep() { [[ "$*" == "-x Google Chrome" ]]; }\nexport -f pgrep\n')
            script.write('gcloud() { return 0; }\nexport -f gcloud\n')
        result = self.harness.invoke('--backend=splash', str(self.harness.target), command='launch-bureaucrat.command')
        assert result.returncode == 0, result.stderr
        config = self.harness.record()['config']
        assert config['default_agent'] == 'qwen-bureaucrat'
        assert config['agent']['qwen-bureaucrat']['model'] == 'splash/' + MODEL
        assert set(config['mcp']) == {'gmail', 'google_drive', 'chrome'}
        assert not self.harness.calls_for('lms')

    def simulate_missing_splash(self) -> Path:
        installed = self.harness.directory / 'splash-installed'
        self.harness.environment['TEST_SPLASH_INSTALLED'] = str(installed)
        with self.harness.shell_environment.open('a') as script:
            script.write('command() { if [[ "$*" == "-v splash" && ! -f "$TEST_SPLASH_INSTALLED" ]]; then return 1; fi; builtin command "$@"; }\nexport -f command\n')
            script.write('brew() { printf "%s\\n" "$*" > "$TEST_SPLASH_INSTALLED"; }\nexport -f brew\n')
        return installed

    def test_coder_installs_missing_splash_then_launches(self) -> None:
        installed = self.simulate_missing_splash()
        self.test_owned_server_stops_and_preserves_client_exit()
        assert installed.read_text() == 'install incoai/tap/splash\n'

    def test_bureaucrat_installs_missing_splash_then_launches(self) -> None:
        installed = self.simulate_missing_splash()
        self.server.shutdown()
        self.server.server_close()
        self.test_bureaucrat_preserves_workspace_tools()
        assert installed.read_text() == 'install incoai/tap/splash\n'

    def test_bureaucrat_install_failure_precedes_workspace_setup(self) -> None:
        self.simulate_missing_splash()
        self.server.shutdown()
        self.server.server_close()
        with self.harness.shell_environment.open('a') as script:
            script.write('brew() { return 42; }\nexport -f brew\n')
        result = self.harness.invoke('--backend=splash', str(self.harness.target), command='launch-bureaucrat.command')
        assert result.returncode == 3, result.stderr
        assert 'Could not install Splash' in result.stderr
        assert not self.harness.record_path.exists()
        assert not (Path(self.harness.environment['HOME']) / '.gmail-mcp').exists()

    def test_missing_homebrew_reports_actionable_error(self) -> None:
        self.simulate_missing_splash()
        self.server.shutdown()
        self.server.server_close()
        with self.harness.shell_environment.open('a') as script:
            script.write('command() { case "$*" in "-v splash"|"-v brew") return 1 ;; esac; builtin command "$@"; }\nexport -f command\n')
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode == 3, result.stderr
        assert 'Install Homebrew' in result.stderr
        assert not self.harness.record_path.exists()

    def test_installation_must_expose_splash_command(self) -> None:
        self.simulate_missing_splash()
        self.server.shutdown()
        self.server.server_close()
        with self.harness.shell_environment.open('a') as script:
            script.write('brew() { return 0; }\nexport -f brew\n')
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode == 3, result.stderr
        assert 'splash is not in PATH' in result.stderr
        assert not self.harness.record_path.exists()

    def test_existing_server_needs_no_installation(self) -> None:
        installed = self.simulate_missing_splash()
        self.test_launcher_uses_splash_context_and_reasoning()
        assert not installed.exists()

    def test_doctor_does_not_install_missing_splash(self) -> None:
        installed = self.simulate_missing_splash()
        self.server.shutdown()
        self.server.server_close()
        result = self.harness.invoke('--backend=splash', command='doctor.command')
        assert result.returncode == 1, result.stderr
        assert not installed.exists()

    def test_port_override_is_rejected(self) -> None:
        self.harness.environment['SPLASH_PORT'] = '8001'
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode == 2, result.stderr
        assert 'Unset SPLASH_PORT' in result.stderr
        assert not self.harness.record_path.exists()

    def test_unrelated_http_service_is_not_replaced(self) -> None:
        self.server.unrelated_service = True
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode == 5, result.stderr
        assert 'not a ready Splash server' in result.stderr
        assert not self.harness.record_path.exists()
        assert not Path(self.harness.environment['TEST_SPLASH_LIFECYCLE']).exists()

    def test_owned_server_stops_and_preserves_client_exit(self):
        self.server.shutdown()
        self.server.server_close()
        self.harness.environment['TEST_OPENCODE_EXIT'] = '17'
        result = self.harness.invoke('--backend=splash', str(self.harness.target))
        assert result.returncode == 17, result.stderr
        assert Path(self.harness.environment['TEST_SPLASH_LIFECYCLE']).read_text() == 'started\nstopped\n'
        assert not (self.harness.directory / 'opencode-qwen3.8-27b.lock').exists()


if __name__ == '__main__' and '--serve' in sys.argv:
    import signal
    parser = argparse.ArgumentParser(prog='splash')
    commands = parser.add_subparsers(dest='command', required=True)
    serve = commands.add_parser('serve')
    serve.add_argument('--model', required=True)
    args = parser.parse_args(sys.argv[2:])
    assert args.model == MODEL
    port = int(os.environ['TEST_SPLASH_PORT'])
    lifecycle = Path(os.environ['TEST_SPLASH_LIFECYCLE'])
    server = start_server(port)
    lifecycle.write_text('started\n')
    def stop(*_args):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        with lifecycle.open('a') as output:
            output.write('stopped\n')
