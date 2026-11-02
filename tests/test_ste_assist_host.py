from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def assist_workspace(tmp_path: Path) -> tuple[Path, Path]:
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
    (repo / ".mprlab").mkdir()
    (repo / ".mprlab/POLICY.md").write_text("Use ASD-STE100 for technical prose.\n")
    (repo / "README.md").write_text("# Guide\n")
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-m", "baseline"], check=True, capture_output=True)
    skill = tmp_path / "governor"
    (skill / "scripts").mkdir(parents=True)
    shared = Path(os.environ.get("MPRLAB_GOVERNOR_SKILL", str(Path.home() / ".config/opencode/skills/mprlab-governor"))).resolve() / "scripts"
    assert (shared / "ste.py").is_file(), "The installed Governor language CLI is required."
    # Inject only the reference boundary. Keep the real CLI and correction logic.
    wrapper = '# /// script\n# dependencies = ["markdown-it-py==4.2.0", "pypdf[crypto]==6.21.4"]\n# ///\nimport sys\nsys.path.insert(0, ' + repr(str(shared)) + ')\nimport ste\nfrom ste_reference import Reference\nreference=Reference({"sha256":"fixture"}, ("Rule 6.6 Keep short paragraphs.\\nPage 1-6-1", "ensure (v) MAKE SURE\\nPage 2-S-1"))\nste.prepare=lambda cache:reference\nraise SystemExit(ste.main())\n'
    (skill / "scripts/ste.py").write_text(wrapper)
    return repo, skill


def test_host_driver_handles_the_loop_without_exposing_it_to_the_agent(assist_workspace: tuple[Path, Path]) -> None:
    repo, skill = assist_workspace
    document = repo / "README.md"
    document.write_text("# Guide\n\nEnsure `API_BASE_URL` stays unchanged.\n")
    script = "import { runAssist } from './scripts/ste-assist.mjs'; const [repo,skill]=process.argv.slice(1); let calls=0; const result=await runAssist({repo,paths:['README.md'],skill,generate:async prompt=>{calls++; if(!prompt.includes('[[L0]]'))throw Error('Missing protected literal'); return 'Make sure [[L0]] stays unchanged.\\n<STE_END>';}}); console.log(JSON.stringify({calls,result}));"
    result = subprocess.run(["node", "--input-type=module", "-e", script, str(repo), str(skill)], cwd=ROOT, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["calls"] == 1
    assert report["result"]["status"] == "mechanical_checks_passed"
    assert document.read_text() == "# Guide\n\nMake sure `API_BASE_URL` stays unchanged.\n"


def test_host_driver_reports_model_failures_and_keeps_source(assist_workspace: tuple[Path, Path]) -> None:
    repo, skill = assist_workspace
    document = repo / "README.md"
    document.write_text("Ensure the file exists.\n")
    script = "import { runAssist } from './scripts/ste-assist.mjs'; const [repo,skill]=process.argv.slice(1); try {await runAssist({repo,paths:['README.md'],skill,generate:async()=>{throw Error('controlled model failure')}}); process.exitCode=1;}catch(error){console.log(error.message)}"
    result = subprocess.run(["node", "--input-type=module", "-e", script, str(repo), str(skill)], cwd=ROOT, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert "controlled model failure" in result.stdout
    assert document.read_text() == "Ensure the file exists.\n"


class AssistHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args: object) -> None:
        pass

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(body)
        if "Correct only the reported language errors" in json.dumps(body["messages"]):
            delta = {"role": "assistant", "content": self.server.replacement}
            finish = "stop"
        elif body.get("tools") and not self.server.written:
            self.server.written = True
            arguments = json.dumps({"path": self.server.document, "content": self.server.original} if self.server.tool == "write" else {"paths": [self.server.document]})
            delta = {"role": "assistant", "tool_calls": [{"index": 0, "id": "write-document", "type": "function", "function": {"name": self.server.tool, "arguments": arguments}}]}
            finish = "tool_calls"
        else:
            delta = {"role": "assistant", "content": "DONE"}
            finish = "stop"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for update, reason in [(delta, None), ({}, finish)]:
            payload = {"id": "chatcmpl-assist", "object": "chat.completion.chunk", "created": 0, "model": "qwen3.8-27b-gguf-q8-mtp", "choices": [{"index": 0, "delta": update, "finish_reason": reason}]}
            self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")


@pytest.mark.parametrize(("original", "replacement", "expected", "status"), [
    ("# Guide\n\nEnsure `API_BASE_URL` stays unchanged.\n", "Make sure [[L0]] stays unchanged.\n<STE_END>", "# Guide\n\nMake sure `API_BASE_URL` stays unchanged.\n", "mechanical_checks_passed"),
    ("The client should use quiet mode.\n", "The client must use quiet mode.\n<STE_END>", "The client should use quiet mode.\n", "meaning_review_required"),
])
@pytest.mark.parametrize("tool", ["write", "ste_assist"])
def test_native_edit_automatically_runs_assistance(assist_workspace: tuple[Path, Path], original: str, replacement: str, expected: str, status: str, tool: str) -> None:
    repo, skill = assist_workspace
    (repo / "unrelated.md").write_text("Ensure this unrelated edit stays unchanged.\n")
    environment = {key: value for key, value in os.environ.items() if not key.startswith(("OPENCODE_", "QWENOC_", "BASH_FUNC_")) and key != "BASH_ENV"}
    config = json.loads(subprocess.check_output(["/bin/bash", "-c", 'sysctl() { printf "68719476736\\n"; }; source scripts/profile.sh; initialize_inference_backend local; runtime_opencode_config_content coder'], cwd=ROOT, env=environment, text=True))
    server = ThreadingHTTPServer(("127.0.0.1", 0), AssistHandler)
    server.requests, server.written, server.original, server.replacement = [], False, original, replacement
    server.document = str(repo / "README.md")
    server.tool = tool
    if tool == "ste_assist":
        (repo / "README.md").write_text(original)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config["providers"]["lmstudio"]["settings"]["baseURL"] = f"http://127.0.0.1:{server.server_port}/v1"
    config["mcp"]["servers"] = {key: {**value, "disabled": True} for key, value in config["mcp"]["servers"].items()}
    host = repo.parent / "host"
    environment.update(PWD=str(repo), HOME=str(host), XDG_CONFIG_HOME=str(host / "config"), XDG_DATA_HOME=str(host / "data"), XDG_STATE_HOME=str(host / "state"), XDG_CACHE_HOME=str(host / "cache"), OPENCODE_CONFIG=str(ROOT / "configs/coder.jsonc"), OPENCODE_CONFIG_DIR=str(ROOT / ".opencode-coder"), OPENCODE_CONFIG_CONTENT=json.dumps(config), OPENCODE_DISABLE_CLAUDE_CODE_SKILLS="true", MPRLAB_GOVERNOR_SKILL=str(skill))
    try:
        result = subprocess.run(["opencode", "run", "--standalone", "--format", "json", "Write the requested technical document."], cwd=repo, env=environment, text=True, capture_output=True, timeout=45)
        assert result.returncode == 0, result.stdout + result.stderr
        assert (repo / "README.md").read_text() == expected, result.stdout + result.stderr
        assert (repo / "unrelated.md").read_text() == "Ensure this unrelated edit stays unchanged.\n"
        assert any("Correct only the reported language errors" in json.dumps(request["messages"]) for request in server.requests)
        assert status in json.dumps(server.requests), result.stdout + "\n" + json.dumps([message for request in server.requests for message in request["messages"] if message.get("role") == "tool"])
    finally:
        server.shutdown()
        server.server_close()
