from __future__ import annotations

import json
from pathlib import Path
import subprocess
import os
import threading
from http.server import ThreadingHTTPServer

from test_sampling import SamplingHandler


ROOT = Path(__file__).resolve().parents[1]


def test_docs_target_delegates_changed_prose_to_shared_cli(tmp_path: Path) -> None:
    skill = tmp_path / "governor with spaces"
    (skill / "scripts").mkdir(parents=True)
    (skill / "scripts/ste.py").write_text("import json,sys\nprint(json.dumps(sys.argv[1:]))\n")
    result = subprocess.run(["make", "--no-print-directory", "-s", "-f", str(ROOT / "Makefile"), "docs", f"MPRLAB_GOVERNOR_SKILL={skill}"], cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    arguments = json.loads(result.stdout)
    assert arguments == ["review", "--repo", str(tmp_path), "--changed"]


def test_docs_target_preserves_language_failures(tmp_path: Path) -> None:
    skill = tmp_path / "governor"
    (skill / "scripts").mkdir(parents=True)
    (skill / "scripts/ste.py").write_text("raise SystemExit(1)\n")
    result = subprocess.run(["make", "--no-print-directory", "-s", "-f", str(ROOT / "Makefile"), "docs", f"MPRLAB_GOVERNOR_SKILL={skill}"], cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0


def test_native_opencode_discovers_the_global_writing_skill(tmp_path: Path) -> None:
    environment = {key: value for key, value in os.environ.items() if not key.startswith(("OPENCODE_", "QWENOC_", "BASH_FUNC_")) and key != "BASH_ENV"}
    config = json.loads(subprocess.check_output(["/bin/bash", "-c", 'sysctl() { printf "68719476736\\n"; }; source scripts/profile.sh; initialize_inference_backend local; runtime_opencode_config_content coder'], cwd=ROOT, env=environment, text=True))
    server = ThreadingHTTPServer(("127.0.0.1", 0), SamplingHandler)
    server.model, server.backend, server.requests = "qwen3.8-27b-gguf-q8-mtp", "local", []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config["providers"]["lmstudio"]["settings"]["baseURL"] = f"http://127.0.0.1:{server.server_port}/v1"
    config["mcp"]["servers"] = {key: {**value, "disabled": True} for key, value in config["mcp"]["servers"].items()}
    skill = tmp_path / "config/opencode/skills/ste-writing"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("---\nname: ste-writing\ndescription: Review technical English through shared language tools.\n---\n\nPreserve technical meaning.\n")
    environment.update(PWD=str(tmp_path), HOME=str(tmp_path), XDG_CONFIG_HOME=str(tmp_path / "config"), XDG_DATA_HOME=str(tmp_path / "data"), XDG_STATE_HOME=str(tmp_path / "state"), XDG_CACHE_HOME=str(tmp_path / "cache"), OPENCODE_CONFIG=str(ROOT / "configs/coder.jsonc"), OPENCODE_CONFIG_DIR=str(ROOT / ".opencode-coder"), OPENCODE_CONFIG_CONTENT=json.dumps(config), OPENCODE_DISABLE_CLAUDE_CODE_SKILLS="true")
    try:
        result = subprocess.run(["opencode", "run", "--standalone", "--format", "json", "Reply SAMPLING_OK. Do not use tools."], cwd=tmp_path, env=environment, text=True, capture_output=True, timeout=45)
        assert result.returncode == 0, result.stdout + result.stderr
        model_inputs = [json.dumps(request["messages"]) for request in server.requests]
        model_inputs.extend(tool["function"]["description"] for request in server.requests for tool in request.get("tools", []) if tool["function"]["name"] == "skill")
        assert any("ste-writing" in text for text in model_inputs)
    finally:
        server.shutdown()
        server.server_close()
