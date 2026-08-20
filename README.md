# QwenOC

QwenOC is a portable local-coding profile for OpenCode, LM Studio, and the Qwen 3.8 27B GGUF Q8_0 model with its bundled Multi-Token Prediction (MTP) head enabled.

The profile keeps inference on the Mac, provides a Qwen-specific system prompt and generation tuning, enables automatic context compaction, and connects the Context7 and `gh_grep` MCP servers for current documentation and public-code examples.

## Why this setup

QwenOC is designed for people who want a capable coding agent running locally, not merely the smallest model or the highest isolated token benchmark. It spends memory on a modern 27B model and an 8-bit quantization, then recovers generation speed with MTP speculative decoding and an optimized Apple Silicon runtime.

| Layer | QwenOC choice | What it contributes |
| --- | --- | --- |
| Model | Qwen 3.8 27B | A dense model trained for coding, autonomous planning, tool feedback, vision, and long-horizon agent work |
| Precision | GGUF Q8_0 | A quality-oriented quantization with substantially more weight precision than a 4-bit build |
| Decoding | Bundled MTP head | Drafts multiple tokens for verification by the same target model, accelerating accepted sequences without substituting a weaker model |
| Runtime | Full GPU offload, Flash Attention, 131K context | Uses Apple unified memory effectively while retaining room for large repositories and tool output |
| Agent harness | Qwen-specific prompt, thinking control, compaction, permissions, and verification commands | Turns the base chat model into a persistent coding workflow instead of relying on generic defaults |
| Tools | Context7 and `gh_grep` only | Adds current documentation and public-code search without loading a large, context-heavy MCP catalog |
| Scheduling | One OpenCode session and one prediction slot | Gives the active coding task the machine's full memory bandwidth and prevents queued requests from timing out |

### Quality: why Qwen 3.8 27B and Q8_0

The [upstream Qwen3.8-27B model card](https://huggingface.co/Qwen/Qwen3.8-27B) reports material improvements over the same-size Qwen3.6-27B predecessor on coding-agent benchmarks:

| Upstream benchmark | Qwen 3.8 27B | Qwen 3.6 27B | Difference |
| --- | ---: | ---: | ---: |
| Terminal Bench 2.1 | 73.0 | 63.4 | +9.6 points |
| SWE-bench Pro | 61.7 | 53.5 | +8.2 points |
| NL2Repo-Bench | 42.3 | 36.2 | +6.1 points |
| QwenSWEBench | 79.0 | 49.3 | +29.7 points |

Those are Qwen's upstream evaluations under the harnesses described in its model card; they are evidence for selecting the base model, not locally reproduced QwenOC scores.

QwenOC then selects Q8_0 and verifies that LM Studio did not silently load a 4-bit variant. Eight bits per quantized weight place less compression pressure on the model than four bits, making this a deliberate quality-first choice. The cost is approximately 30 GB of model storage and a 64 GiB Mac. A task-level Q8-versus-Q4 quality evaluation has not yet been published for this profile, so QwenOC does not claim a numerical quality uplift from quantization alone.

### Speed: what MTP changes

[LM Studio describes speculative decoding](https://lmstudio.ai/docs/app/advanced/speculative-decoding) as a way to increase generation speed without reducing response quality: proposed tokens are checked by the target model and rejected when they do not match its generation. Qwen3.8-27B is trained with multiple MTP steps, and this profile loads its bundled MTP head rather than a separate general-purpose draft model.

On the tested 64 GiB Mac, eight completed coding generations showed:

- 6,977 generated tokens at a token-weighted **13.41 tokens/second**, or about **805 tokens/minute**
- **92.24% MTP acceptance**: 3,813 of 4,134 drafted tokens were accepted
- A **15.80 tokens/second median**, with an observed 12.44–20.15 tokens/second range
- Prompt processing at approximately 86–130 tokens/second

The high acceptance rate confirms that the MTP path is doing useful speculative work on these coding prompts. This is measured end-to-end throughput, not a claimed MTP speed-up percentage: the same GGUF has not yet been benchmarked on this Mac with MTP disabled under an otherwise identical workload.

### What the OpenCode profile adds

The model is only one part of an agent. [OpenCode supports custom agents](https://opencode.ai/docs/agents/) with their own prompt, model, permissions, and generation controls; QwenOC uses that surface to provide:

- `low`, `medium`, and `xhigh` reasoning-effort modes with preserved thinking across turns
- A coding-specific system prompt that requires inspection, implementation, testing, repair, and an evidence-backed finish
- Automatic context compaction with a 32K output reserve and task-state preservation
- `/finish` and `/verify` workflows for completion and final repository auditing
- Narrowly selected [MCP tools](https://opencode.ai/docs/mcp-servers/) for documentation and public-code search
- Exact model, quantization, MTP, context, and server checks before work begins
- A single-session guard and a local-inference-safe timeout policy

### Compared with common alternatives

| Alternative | QwenOC advantage | Alternative advantage |
| --- | --- | --- |
| Qwen 27B at 4-bit | More weight precision and a configuration that refuses silent Q4 fallback | Lower memory use; may decode faster and fit smaller Macs |
| The same Q8 model without MTP | Speculative drafts can reduce sequential target-model work when acceptance is high | Simpler baseline with no speculative overhead; an A/B benchmark is still needed |
| A smaller 7B–14B local model | More model capacity for repository reasoning and long-horizon agent work | Faster generation, lower memory pressure, and easier parallel use |
| A generic OpenCode local-model configuration | Qwen-specific reasoning controls, prompt, compaction, MCP selection, diagnostics, and runtime safeguards | Less opinionated and easier to adapt to unrelated models |
| Multiple local sessions | Stable single-task speed, full context capacity, and no head-of-line queue | Higher aggregate concurrency on machines with more memory bandwidth |
| A frontier cloud coding model | Local source privacy, no inference subscription or per-token charge, no provider rate limit, and operation without inference-network latency | Cloud models may offer higher absolute capability, faster hardware, and managed availability |

The result is a specific sweet spot: higher-fidelity local inference than a memory-first 4-bit setup, materially more capability than a small local model, and responsive generation for sustained coding work—while remaining transparent about the hardware cost and the areas that still need controlled A/B evaluation.

## Tested configuration

- Apple Silicon Mac with 64 GiB unified memory
- macOS 26.6.2
- LM Studio 0.4.21+2
- LM Studio llama.cpp runtime 2.28.2
- OpenCode 1.18.17
- Qwen 3.8 27B GGUF Q8_0, approximately 30 GB on disk
- 131,072-token context, full GPU offload, Flash Attention, one prediction slot and one OpenCode session
- Bundled MTP speculative decoding with a measured 92.24% aggregate draft-token acceptance rate

This repository contains configuration and scripts. The installer downloads the model directly through LM Studio.

## Requirements

- An Apple Silicon Mac
- At least 64 GiB physical memory for this exact Q8_0 and 131,072-token profile
- At least 35 GiB free before the model download
- [Homebrew](https://brew.sh/)
- Internet access during installation and for the two configured MCP servers

## Install

Clone the repository, enter its directory, and run the installer:

```bash
git clone https://github.com/tyemirov/QwenOC.git
cd QwenOC
./install.command
```

The installer is idempotent. It:

1. Verifies Apple Silicon and physical memory.
2. Installs LM Studio, OpenCode, and `jq` through Homebrew when needed.
3. Confirms that LM Studio supports `--speculative-draft-mtp`.
4. Downloads the exact `qwen/qwen3.8-27b@q8_0` GGUF model when needed.
5. Starts the LM Studio API server.
6. Loads the model with MTP and the canonical 131,072-token context.
7. Runs the full doctor check.

If another Qwen 3.8 variant is already selected, the installer opens LM Studio and identifies the one manual selection required: My Models > Qwen3.8 27B > Variants > Q8_0 MTP GGUF.

## Launch

Double-click `launch-opencode.command` and choose a project folder, or pass a project directly:

```bash
./launch-opencode.command ~/Development/my-project
```

The launcher starts the LM Studio API server when needed, verifies the exact installed and selected model, and reloads an idle dedicated instance when its context or MTP configuration differs. It enforces one OpenCode session for the one-slot model, then starts OpenCode with this repository's configuration and plugin directory.

LM Studio remains running when OpenCode exits. Stop it explicitly when desired:

```bash
lms server stop
```

## Verify the installation

Run diagnostics against this profile alone:

```bash
./doctor.command
```

Run diagnostics against the configuration as resolved inside a specific project:

```bash
./doctor.command ~/Development/my-project
```

The doctor checks:

- Host architecture and memory
- Required command-line tools and minimum OpenCode version
- Exact GGUF Q8_0 installation and LM Studio source selection
- Live 131,072-token context, Flash Attention, and `speculative_draft_mtp: true`
- Resolved OpenCode model, agent, compaction, and MCP settings
- Live Context7 and `gh_grep` connections

The launcher also exposes the same check:

```bash
./launch-opencode.command --doctor ~/Development/my-project
```

## Agent controls

- `qwen-local` is the default primary agent.
- Press `Ctrl+T` in OpenCode to cycle the `low`, `medium`, and `xhigh` reasoning variants. `medium` is the default.
- Run `/finish` to continue an implementation until its acceptance criteria and verification are complete.
- Run `/verify` for a final repository diff and test audit.
- Automatic compaction is enabled with pruning and a 32,000-token reserve.
- The provider uses one 30-minute request deadline. It does not impose a shorter between-chunk SSE deadline while LM Studio is processing a long prompt.

The local plugin applies the model's generation defaults and adds task state, verification evidence, unresolved failures, and the next action to OpenCode's compaction context.

## Detailed performance record

Eight completed MTP generations produced 6,977 tokens:

- Token-weighted generation speed: 13.41 tokens/second
- Median run: 15.80 tokens/second
- Observed range: 12.44–20.15 tokens/second
- Long coding generations: approximately 12.4–13.0 tokens/second
- MTP drafts accepted: 3,813 of 4,134, or 92.24%

Prompt processing is separate from generation. The tested system processed long prompts at approximately 86–130 tokens/second.

## Runtime hygiene

This 64 GiB profile deliberately runs one OpenCode session against one LM Studio prediction slot. The launcher uses a single-session lock and reports the PID of an existing session instead of creating a competing queue.

If OpenCode reports `SSE read timed out`, close the existing profile session and relaunch through `launch-opencode.command`. The doctor reports more than one competing profile session as a failure.

Claude-compatible skill discovery is disabled for this profile so that skills already exposed through `.agents/skills` or this profile's `.opencode/skills` directory are not loaded a second time from `.claude/skills`.

## Configuration boundaries

OpenCode merges custom, global, and target-project configuration. The launcher passes the model and agent explicitly, while the doctor verifies that the final resolved configuration still preserves this profile's critical settings. A managed organization configuration can retain higher precedence.

The model API listens on `127.0.0.1:1234`. OpenCode session sharing is disabled. Context7 and `gh_grep` make outbound network requests when used.

## Repository contents

```text
install.command                 One-time idempotent setup
launch-opencode.command         Runtime launcher
doctor.command                  Non-destructive configuration audit
scripts/profile.sh              Canonical model and runtime contract
opencode.jsonc                  OpenCode provider, model, agent, MCP, and compaction settings
prompts/qwen-local.txt          Qwen-specific coding-agent system prompt
.opencode/plugins/qwen-local.ts Generation and compaction hooks
.opencode/commands/             /finish and /verify commands
```

## Licensing and attribution

The scripts and configuration in this repository are released under the [MIT License](LICENSE).

The model is downloaded separately from [lmstudio-community/Qwen3.8-27B-GGUF](https://huggingface.co/lmstudio-community/Qwen3.8-27B-GGUF), is based on `Qwen/Qwen3.8-27B`, and is distributed under the Apache-2.0 license stated on its model repository. LM Studio and OpenCode retain their respective licenses and trademarks.

QwenOC is an independent community project and is not affiliated with or endorsed by Qwen, OpenCode, or LM Studio.
