from __future__ import annotations

import json
import os
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
LOCAL_MODEL = "lmstudio/qwen3.8-27b"

STUB_HELPER = r"""
import json
import os
from pathlib import Path
import sys

command, *arguments = sys.argv[1:]
log_path = Path(os.environ['TEST_CALL_LOG'])
with log_path.open('a') as log_file:
    log_file.write(json.dumps({'command': command, 'arguments': arguments}) + '\n')

if command == 'opencode':
    if arguments == ['--version']:
        print('1.18.17')
        sys.exit(0)
    config = json.loads(os.environ['OPENCODE_CONFIG_CONTENT'])
    record = {
        'arguments': arguments,
        'config': config,
        'config_file': os.environ['OPENCODE_CONFIG'],
        'config_dir': os.environ['OPENCODE_CONFIG_DIR'],
        'cwd': str(Path.cwd()),
    }
    Path(os.environ['TEST_OPENCODE_RECORD']).write_text(json.dumps(record))
    if arguments[:2] == ['debug', 'config']:
        # The external OpenCode process is a controlled boundary in these tests.
        # This does not qualify the live provider or OpenCode's config loader.
        print(json.dumps(config))
    elif arguments[:2] == ['mcp', 'list']:
        print('context7 connected\ngh_grep connected')
    elif arguments[:1] == ['run']:
        print(json.dumps({'type': 'text', 'part': {'text': 'OK'}}))
    sys.exit(int(os.environ.get('TEST_OPENCODE_EXIT', '0')))

if command == 'sysctl':
    if os.environ.get('TEST_LOCAL_ALLOWED') != '1':
        sys.exit(91)
    print(64 * 1073741824)
elif command == 'uname':
    print('Darwin' if arguments == ['-s'] else 'arm64')
elif command == 'pgrep':
    sys.exit(1)
elif command == 'lms':
    if os.environ.get('TEST_LOCAL_ALLOWED') != '1':
        sys.exit(92)
    variant = 'qwen/qwen3.8-27b@q8_0'
    if arguments[:1] == ['ls']:
        print(json.dumps([{
            'modelKey': variant if len(arguments) > 2 else 'qwen/qwen3.8-27b',
            'selectedVariant': variant,
            'format': 'gguf', 'quantization': {'name': 'Q8_0', 'bits': 8},
        }]))
    elif arguments[:1] == ['load']:
        Path(os.environ['TEST_LOCAL_LOADED']).write_text('loaded')
    elif arguments[:1] == ['unload']:
        Path(os.environ['TEST_LOCAL_LOADED']).unlink(missing_ok=True)
    elif arguments[:1] == ['ps']:
        print(json.dumps([{'identifier': 'qwen3.8-27b-gguf-q8-mtp', 'status': 'idle'}]))
elif command == 'curl':
    if os.environ.get('TEST_LOCAL_ALLOWED') != '1':
        sys.exit(93)
    model_id = 'qwen3.8-27b-gguf-q8-mtp'
    if any('/api/v1/models' in argument for argument in arguments):
        loaded = Path(os.environ['TEST_LOCAL_LOADED']).exists()
        print(json.dumps({'models': [{
            'selected_variant': 'qwen/qwen3.8-27b@q8_0', 'format': 'gguf',
            'quantization': {'name': 'Q8_0', 'bits_per_weight': 8},
            'loaded_instances': [{'id': model_id, 'config': {
                'context_length': 131072, 'parallel': 1,
                'flash_attention': True, 'speculative_draft_mtp': True,
            }}] if loaded else [],
        }]}))
    else:
        print(json.dumps({'data': [{'id': model_id}]}))
else:
    sys.exit(94)
"""


class BackendLaunchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="qwenoc-backend-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.profile = self.directory / "profile with spaces"
        self.profile.mkdir()
        for source_path in PROJECT_ROOT.rglob("*"):
            if source_path.is_file() and not any(
                part in {".git", "__pycache__", "node_modules"}
                for part in source_path.parts
            ):
                relative_path = source_path.relative_to(PROJECT_ROOT)
                if source_path.name == ".env" or source_path.name.startswith(".env."):
                    continue
                destination = self.profile / relative_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source_path.read_bytes())
        self.target = self.directory / "target with spaces"
        self.target.mkdir()
        self.calls = self.directory / "calls.jsonl"
        self.record_path = self.directory / "opencode.json"
        self.helper = self.directory / "stub_helper.py"
        self.helper.write_text(STUB_HELPER)
        self.shell_environment = self.directory / "shell-environment.sh"
        functions = []
        for command in [
            "opencode",
            "lms",
            "sysctl",
            "uname",
            "pgrep",
            "curl",
            "open",
            "brew",
        ]:
            functions.append(
                f'{command}() {{ "{sys.executable}" "$TEST_HELPER" {command} "$@"; }}\nexport -f {command}\n'
            )
        self.shell_environment.write_text("".join(functions))
        # Existing launchers check a resolved command path before shell dispatch.
        for command in ["opencode", "lms"]:
            (self.directory / command).symlink_to(
                shutil.which("true") or "/usr/bin/true"
            )
        self.environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("OPENCODE_", "QWENOC_", "BASH_FUNC_"))
        }
        self.environment.update(
            {
                "HOME": str(self.directory / "home"),
                "TMPDIR": str(self.directory),
                "BASH_ENV": str(self.shell_environment),
                "TEST_HELPER": str(self.helper),
                "TEST_CALL_LOG": str(self.calls),
                "TEST_OPENCODE_RECORD": str(self.record_path),
                "TEST_LOCAL_LOADED": str(self.directory / "local-loaded"),
            }
        )
        Path(self.environment["HOME"]).mkdir()

    def invoke(
        self, *arguments: str, command: str = "launch-coder.command"
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(self.profile / command), *arguments],
            cwd=self.directory,
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=15,
        )

    def record(self) -> dict:
        return json.loads(self.record_path.read_text())

    def calls_for(self, command: str) -> list[dict]:
        if not self.calls.exists():
            return []
        return [
            entry
            for line in self.calls.read_text().splitlines()
            if (entry := json.loads(line))["command"] == command
        ]

    def assert_no_local_calls(self) -> None:
        for command in ["lms", "sysctl", "pgrep", "curl", "open", "brew"]:
            self.assertEqual(self.calls_for(command), [], command)
        self.assertFalse((self.directory / "opencode-qwen3.8-27b.lock").exists())

    def test_removed_backend_is_rejected_by_all_entrypoints(self) -> None:
        for command in ["install.command", "doctor.command", "launch-coder.command",
                        "launch-opencode.command", "launch-bureaucrat.command"]:
            with self.subTest(command=command):
                result = self.invoke("--backend", "bedrock", command=command)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.record_path.exists())
                self.assert_no_local_calls()

    def test_local_default_does_not_source_dotenv(self) -> None:
        self.environment["TEST_LOCAL_ALLOWED"] = "1"
        (self.profile / "configs/.env").write_text("echo SHOULD_NOT_RUN; exit 88\n")
        result = self.invoke(str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.record()
        self.assertEqual(record["config"]["model"], LOCAL_MODEL)
        self.assertEqual(record["config"]["agent"]["qwen-local"]["variant"], "medium")
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)
        operations = [entry["arguments"][0] for entry in self.calls_for("lms")]
        self.assertIn("load", operations)
        self.assertIn("unload", operations)
        self.assertFalse((self.directory / "opencode-qwen3.8-27b.lock").exists())

    def test_explicit_local_matches_default(self) -> None:
        self.environment["TEST_LOCAL_ALLOWED"] = "1"
        result = self.invoke("--backend", "local", str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.record()["config"]["model"], LOCAL_MODEL)

    def test_bad_backend_is_rejected_without_local_probe(self) -> None:
        result = self.invoke("--backend", "invalid", str(self.target))
        self.assertEqual(result.returncode, 2)
        self.assertIn("backend", result.stderr.lower())
        self.assert_no_local_calls()

    def test_help_does_not_probe_memory(self) -> None:
        result = self.invoke("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--backend", result.stdout)
        self.assert_no_local_calls()

    def test_empty_backend_value_fails_early(self) -> None:
        result = self.invoke("--backend=")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assert_no_local_calls()

    def test_missing_backend_argument_fails_early(self) -> None:
        result = self.invoke("--backend")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assert_no_local_calls()

if __name__ == "__main__":
    unittest.main(verbosity=2)
