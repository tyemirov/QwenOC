from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('wrapper,tool_name', [
    ('mcp-gmail.mjs', 'search_emails'),
    ('mcp-google-drive.mjs', 'search'),
])
def test_tool_schema_through_mcp_stdio(wrapper: str, tool_name: str, tmp_path: Path) -> None:
    schema = {
        'type': 'object', '$schema': 'https://json-schema.org/draft/2020-12/schema',
        'additionalProperties': False,
        'required': ['pattern', '$schema', 'additionalProperties'],
        'properties': {
            'pattern': {'type': 'string', 'pattern': '^query$'},
            '$schema': {'type': 'string'},
            'additionalProperties': {'type': 'boolean'},
            'nested': {'type': 'array', 'items': {'type': 'object', 'properties': {
                'pattern': {'type': 'string', 'pattern': '^nested$'},
            }, 'required': ['pattern'], 'additionalProperties': False}},
            'choice': {'anyOf': [{'type': 'string', 'pattern': '^choice$'}, {'type': 'null'}]},
            'literal': {'type': 'object', 'default': {'pattern': 'keep', 'additionalProperties': False}},
        },
        '$defs': {'pattern': {'type': 'string', 'pattern': '^definition$'}},
    }
    response = {'jsonrpc': '2.0', 'id': 1, 'result': {'tools': [
        {'name': tool_name, 'inputSchema': schema},
        {'name': 'excluded_tool', 'inputSchema': {'type': 'object'}},
    ]}}
    upstream = tmp_path / 'upstream.mjs'
    upstream.write_text(
        'import readline from "node:readline";\n'
        'readline.createInterface({ input: process.stdin }).once("line", () => {\n'
        '  process.stdout.write(process.env.TEST_MCP_RESPONSE + "\\n", () => process.exit(0));\n'
        '});\n'
    )
    loader = tmp_path / 'transport.mjs'
    loader.write_text(
        'import childProcess from "node:child_process";\n'
        'import { syncBuiltinESMExports } from "node:module";\n'
        'const spawn = childProcess.spawn;\n'
        'childProcess.spawn = (command, args, options) => {\n'
        '  if (command !== "npx") throw new Error("Unexpected upstream command");\n'
        '  return spawn(process.execPath, [process.env.TEST_MCP_UPSTREAM], options);\n'
        '};\n'
        'syncBuiltinESMExports();\n'
    )
    environment = dict(os.environ, TEST_MCP_UPSTREAM=str(upstream), TEST_MCP_RESPONSE=json.dumps(response))
    result = subprocess.run(
        ['node', '--import', str(loader), str(ROOT / 'scripts' / wrapper)],
        input=json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}) + '\n',
        env=environment, text=True, capture_output=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    tools = json.loads(result.stdout)['result']['tools']
    assert [tool['name'] for tool in tools] == [tool_name]
    sanitized = tools[0]['inputSchema']
    assert sanitized['required'] == ['pattern', '$schema', 'additionalProperties']
    assert sanitized['properties']['pattern'] == {'type': 'string'}
    assert sanitized['properties']['$schema'] == {'type': 'string'}
    assert sanitized['properties']['additionalProperties'] == {'type': 'boolean'}
    assert not {'$schema', 'additionalProperties'} & sanitized.keys()
    nested = sanitized['properties']['nested']['items']
    assert nested['properties']['pattern'] == {'type': 'string'}
    assert nested['required'] == ['pattern']
    assert 'additionalProperties' not in nested
    assert sanitized['properties']['choice']['anyOf'] == [{'type': 'string'}, {'type': 'null'}]
    assert sanitized['$defs']['pattern'] == {'type': 'string'}
    assert sanitized['properties']['literal']['default'] == {'pattern': 'keep', 'additionalProperties': False}
    assert sanitized['properties']['literal']['properties'] == {
        '_placeholder': {'type': 'string', 'description': 'Optional parameter'},
    }
