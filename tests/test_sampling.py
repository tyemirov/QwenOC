from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

ROOT = Path(__file__).resolve().parents[1]


class SamplingHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args: object) -> None:
        pass

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.requests.append(body)
        # Splash 1.0 server/protocol.py: MAX_TOP_K = 32.
        if self.server.backend == 'splash' and not 1 <= body.get('top_k', 20) <= 32:
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': {'type': 'invalid_request_error',
                                                 'message': 'invalid sampling parameters'}}).encode())
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        text = 'SAMPLING_OK'
        if not body.get('tools') and 'You MUST use this format for your response' in json.dumps(body['messages']):
            text = '## Objective\n- Reply SAMPLING_OK.\n\n## Work State\n### Completed\n- First reply.\n\n## Next Move\n1. Continue.\n'
        for delta, finish in [({'role': 'assistant', 'content': text}, None),
                              ({}, 'stop')]:
            payload = {'id': 'chatcmpl-test', 'object': 'chat.completion.chunk',
                       'created': 0, 'model': self.server.model,
                       'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
            if finish == 'stop':
                payload['usage'] = {'prompt_tokens': getattr(self.server, 'reported_input_tokens', 0),
                                    'completion_tokens': 10, 'total_tokens': getattr(self.server, 'reported_input_tokens', 0) + 10}
            self.wfile.write(('data: ' + json.dumps(payload) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n')


@pytest.mark.parametrize('role', ['coder', 'bureaucrat'])
@pytest.mark.parametrize('backend,memory,model_id', [
    ('splash', 48, 'incoai/Qwen3.8-27B-Splash'),
    ('splash', 64, 'unsloth/Qwen3.8-27B-GGUF:Q8_0'),
    ('local', 32, 'qwen3.8-27b-gguf-q4-mtp'),
    ('local', 48, 'qwen3.8-27b-gguf-q6-mtp'),
    ('local', 64, 'qwen3.8-27b-gguf-q8-mtp'),
])
@pytest.mark.parametrize('effort', [None, 'low', 'medium', 'xhigh'])
def test_sampling_through_opencode(role: str, backend: str, memory: int,
                                  model_id: str, effort: str | None, tmp_path: Path, compact: bool = False) -> None:
    opencode = shutil.which('opencode')
    if opencode is None:
        pytest.fail('OpenCode 2.2.5 or newer is required for client qualification')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('SPLASH_', 'OPENCODE_', 'QWENOC_', 'BASH_FUNC_')) and key != 'BASH_ENV'}
    config = json.loads(subprocess.check_output(
        ['/bin/bash', '-c', f'set -euo pipefail; sysctl() {{ printf "%s\\n" {memory * 1073741824}; }}; source scripts/profile.sh; '
         f'initialize_inference_backend {backend}; runtime_opencode_config_content {role}'],
        cwd=ROOT, env=environment, text=True))
    provider = 'splash' if backend == 'splash' else 'lmstudio'
    selection = config['model']
    catalog_id = selection.removeprefix(provider + '/')
    server = ThreadingHTTPServer(('127.0.0.1', 0), SamplingHandler)
    server.model, server.backend, server.requests = model_id, backend, []
    if compact:
        config['providers'][provider]['models'][catalog_id]['limit'] = {'context': 16384, 'output': 8192}
        config['compaction']['buffer'] = 8192
        server.reported_input_tokens = 14000
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        # Inject only external transports. Keep the real config, plugin, and client.
        config['providers'][provider]['settings']['baseURL'] = f'http://127.0.0.1:{server.server_port}/v1'
        config['mcp']['servers'] = {key: {**value, 'disabled': True} for key, value in config['mcp']['servers'].items()}
        environment.update(HOME=str(tmp_path), XDG_DATA_HOME=str(tmp_path / 'data'),
                           XDG_STATE_HOME=str(tmp_path / 'state'), XDG_CACHE_HOME=str(tmp_path / 'cache'),
                           OPENCODE_CONFIG=str(ROOT / f'configs/{role}.jsonc'),
                           OPENCODE_CONFIG_DIR=str(ROOT / f'.opencode-{role}'),
                           OPENCODE_CONFIG_CONTENT=json.dumps(config),
                           OPENCODE_DISABLE_CLAUDE_CODE_SKILLS='true')
        if effort is None:
            inspected = subprocess.run(
                [opencode, 'debug', 'config', '--standalone', '--print-logs'],
                cwd=tmp_path, env=environment, text=True, capture_output=True, timeout=30)
            assert inspected.returncode == 0, inspected.stderr
            assert 'configuration normalization diagnostic' not in inspected.stderr, inspected.stderr
            documents = [entry['info'] for entry in json.loads(inspected.stdout) if entry['type'] == 'document']
            assert documents[-1]['agents'][config['default_agent']]['system']
            assert documents[-1]['providers'][provider]['models'][catalog_id]['limit'] == config['providers'][provider]['models'][catalog_id]['limit']
            resolved = subprocess.run(
                ['/bin/bash', '-c', 'source "$1/scripts/profile.sh"; OPENCODE_BIN="$2"; resolved_opencode_config',
                 'config-check', str(ROOT), opencode],
                cwd=tmp_path, env=environment, text=True, capture_output=True, timeout=30)
            assert resolved.returncode == 0, resolved.stderr
            effective = json.loads(resolved.stdout)
            assert effective['model'] == selection
            assert effective['agents'][config['default_agent']]['model'] == config['agents'][config['default_agent']]['model']
            assert effective['compaction']['buffer'] == config['compaction']['buffer']
        if effort is None:
            # Exercise the configured default model, role, and reasoning variant.
            options = []
        else:
            options = ['--model', selection + '#' + effort]
        result = subprocess.run(
            [opencode, 'run', '--standalone', *options, '--format', 'json',
             'Reply SAMPLING_OK. Do not use tools.'],
            cwd=tmp_path, env=environment, text=True, capture_output=True, timeout=45)
        assert result.returncode == 0, result.stdout + result.stderr
        assert server.requests, result.stdout
        expected_top_k = 40 if backend == 'local' and role == 'bureaucrat' else 20
        assert all(request.get('top_k') == expected_top_k for request in server.requests)
        assert all(request['model'] == model_id for request in server.requests)
        assert all(request['temperature'] == (0.5 if role == 'bureaucrat' else 1.0) and
                   request['top_p'] == (0.9 if role == 'bureaucrat' else 0.95) for request in server.requests)
        primary = [request for request in server.requests if request.get('tools')]
        assert primary, server.requests
        expected_effort = effort or ('low' if role == 'bureaucrat' else 'medium')
        for request in primary:
            if backend == 'splash':
                assert request['reasoning_effort'] == expected_effort
            else:
                assert request['chat_template_kwargs'] == {
                    'enable_thinking': True, 'preserve_thinking': True, 'reasoning_effort': expected_effort}
            assert 0 < request['max_tokens'] <= config['providers'][provider]['models'][catalog_id]['limit']['output']
            if role == 'bureaucrat':
                tools = {tool['function']['name']: tool['function']['parameters'] for tool in request['tools']}
                for name in ['glob', 'grep']:
                    assert tools[name]['properties']['pattern']['type'] == 'string'
                    assert 'pattern' in tools[name]['required']
                def check_schema(schema: dict) -> None:
                    assert not {'pattern', 'additionalProperties', '$schema'} & schema.keys()
                    for child in schema.get('properties', {}).values():
                        check_schema(child)
                    if isinstance(schema.get('items'), dict):
                        check_schema(schema['items'])
                    for keyword in ['allOf', 'anyOf', 'oneOf', 'prefixItems']:
                        for child in schema.get(keyword, []):
                            check_schema(child)
                for schema in tools.values():
                    check_schema(schema)
        assert 'SAMPLING_OK' in result.stdout
        assert 'invalid sampling parameters' not in result.stdout
        if compact:
            session_id = next(json.loads(line)['sessionID'] for line in result.stdout.splitlines()
                              if 'sessionID' in json.loads(line))
            server.requests.clear()
            continued = subprocess.run(
                [opencode, 'run', '--standalone', '--session', session_id, '--format', 'json',
                 'Continue. Reply SAMPLING_OK. Do not use tools.'],
                cwd=tmp_path, env=environment, text=True, capture_output=True, timeout=45)
            assert continued.returncode == 0, continued.stdout + continued.stderr
            expected = ("Preserve the user's current acceptance criteria" if role == 'coder' else
                        'Preserve all pending email drafts')
            assert any(expected in json.dumps(request['messages']) for request in server.requests), continued.stdout

    finally:
        server.shutdown()
        server.server_close()


@pytest.mark.parametrize('role', ['coder', 'bureaucrat'])
@pytest.mark.parametrize('memory,model_id', [
    (48, 'incoai/Qwen3.8-27B-Splash'),
    (64, 'unsloth/Qwen3.8-27B-GGUF:Q8_0'),
])
def test_splash_without_thinking(role: str, memory: int, model_id: str, tmp_path: Path) -> None:
    test_sampling_through_opencode(role, 'splash', memory, model_id, 'none', tmp_path)


@pytest.mark.parametrize('role', ['coder', 'bureaucrat'])
def test_compaction_through_opencode(role: str, tmp_path: Path) -> None:
    test_sampling_through_opencode(role, 'splash', 48, 'incoai/Qwen3.8-27B-Splash', None, tmp_path, compact=True)
