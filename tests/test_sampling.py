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
MODEL = 'incoai/Qwen3.8-27B-Splash'


class SamplingHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args: object) -> None:
        pass

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.requests.append(body)
        # Splash 1.0 server/protocol.py: MAX_TOP_K = 32.
        if not 1 <= body.get('top_k', 20) <= 32:
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': {'type': 'invalid_request_error',
                                                 'message': 'invalid sampling parameters'}}).encode())
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for delta, finish in [({'role': 'assistant', 'content': 'SAMPLING_OK'}, None),
                              ({}, 'stop')]:
            payload = {'id': 'chatcmpl-test', 'object': 'chat.completion.chunk',
                       'created': 0, 'model': MODEL,
                       'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
            self.wfile.write(('data: ' + json.dumps(payload) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n')


@pytest.mark.parametrize('effort', ['none', 'low', 'medium', 'xhigh'])
def test_bureaucrat_sampling_through_opencode(effort: str, tmp_path: Path) -> None:
    opencode = shutil.which('opencode')
    if opencode is None:
        pytest.skip('OpenCode is required for the client protocol qualification')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('SPLASH_', 'OPENCODE_', 'BASH_FUNC_')) and key != 'BASH_ENV'}
    config = json.loads(subprocess.check_output(
        ['/bin/bash', '-c', 'set -euo pipefail; source scripts/profile.sh; '
         'initialize_inference_backend splash; runtime_opencode_config_content bureaucrat'],
        cwd=ROOT, env=environment, text=True))
    server = ThreadingHTTPServer(('127.0.0.1', 0), SamplingHandler)
    server.requests = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        # Inject the provider URL and disable external MCP transports, keeping
        # the actual role configuration, tuning plugin, SDK, and client real.
        config['provider']['splash']['options']['baseURL'] = f'http://127.0.0.1:{server.server_port}/v1'
        config['mcp'] = {key: {**value, 'enabled': False} for key, value in config['mcp'].items()}
        environment.update(OPENCODE_CONFIG=str(ROOT / 'configs/bureaucrat.jsonc'),
                           OPENCODE_CONFIG_DIR=str(ROOT / '.opencode-bureaucrat'),
                           OPENCODE_CONFIG_CONTENT=json.dumps(config),
                           OPENCODE_DISABLE_CLAUDE_CODE_SKILLS='true', QWENOC_OUTPUT_LIMIT='8192')
        result = subprocess.run(
            [opencode, 'run', '--model', 'splash/' + MODEL, '--agent', 'qwen-bureaucrat',
             '--variant', effort, '--format', 'json', 'Reply SAMPLING_OK. Do not use tools.'],
            cwd=tmp_path, env=environment, text=True, capture_output=True, timeout=45)
        assert result.returncode == 0, result.stderr
        assert server.requests, result.stdout
        assert all(request.get('top_k') == 20 for request in server.requests), [
            request.get('top_k') for request in server.requests]
        assert any(request.get('reasoning_effort') == effort for request in server.requests)
        assert all(request['model'] == MODEL for request in server.requests)
        assert all(request['temperature'] == 0.5 and request['top_p'] == 0.9 for request in server.requests)
        assert 'SAMPLING_OK' in result.stdout
        assert 'invalid sampling parameters' not in result.stdout
    finally:
        server.shutdown()
        server.server_close()
