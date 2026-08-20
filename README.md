# QwenOC

QwenOC is a portable local-coding profile for OpenCode, LM Studio, and Qwen 3.8 27B with its bundled Multi-Token Prediction (MTP) head enabled. It detects Apple unified memory at startup and maps the machine to an exact GGUF quantization and context budget.

The profile keeps inference on the Mac, provides a Qwen-specific system prompt and generation tuning, enables automatic context compaction, and connects the Context7 and `gh_grep` MCP servers for current documentation and public-code examples.

## Why this setup

QwenOC is designed for people who want a capable coding agent running locally, not merely the smallest model or the highest isolated token benchmark. It spends the memory available on the highest configured precision, then recovers generation speed with MTP speculative decoding and an optimized Apple Silicon runtime.

| Layer | QwenOC choice | What it contributes |
| --- | --- | --- |
| Model | Qwen 3.8 27B | A dense model trained for coding, autonomous planning, tool feedback, vision, and long-horizon agent work |
| Precision | Q8_0, Q6_K, or Q4_K_M selected from RAM | Uses the highest configured tier that fits the machine instead of silently accepting LM Studio's current variant |
| Decoding | Bundled MTP head | Drafts multiple tokens for verification by the same target model, accelerating accepted sequences without substituting a weaker model |
| Runtime | Full GPU offload, Flash Attention, tiered context | Uses Apple unified memory while scaling context and output reserves with model size |
| Agent harness | Qwen-specific prompt, thinking control, compaction, permissions, and verification commands | Turns the base chat model into a persistent coding workflow instead of relying on generic defaults |
| Tools | Context7 and `gh_grep` only | Adds current documentation and public-code search without loading a large, context-heavy MCP catalog |
| Scheduling | One OpenCode session and one prediction slot | Gives the active coding task the machine's full memory bandwidth and prevents queued requests from timing out |

### Adaptive memory profiles

The canonical map lives in [`config/model-tiers.tsv`](config/model-tiers.tsv). `install.command`, `launch-opencode.command`, and `doctor.command` read the same file every time they start.

| Detected unified memory | Profile | Exact quantization | Context | Output and compaction reserve | Minimum free space before download |
| ---: | --- | --- | ---: | ---: | ---: |
| 64 GiB or more | quality | Q8_0 | 131,072 | 32,000 | 35 GiB |
| 48–63 GiB | balanced | Q6_K | 65,536 | 16,384 | 28 GiB |
| 32–47 GiB | compact | Q4_K_M | 32,768 | 8,192 | 22 GiB |

The launcher verifies the exact downloaded and selected variant before loading it. A machine with multiple installed variants may require one LM Studio source selection; subsequent launches verify that choice and stop with the precise correction if it changes. Machines below 32 GiB are reported as unsupported by the current map.

The quality/Q8_0 tier is measured on the 64 GiB test Mac. The balanced and compact tiers have configuration-level validation, but their throughput and maximum sustained memory use still need measurements on 48 GiB and 32 GiB hardware.

### Quality: why Qwen 3.8 27B and adaptive precision

The [upstream Qwen3.8-27B model card](https://huggingface.co/Qwen/Qwen3.8-27B) reports material improvements over the same-size Qwen3.6-27B predecessor on coding-agent benchmarks:

| Upstream benchmark | Qwen 3.8 27B | Qwen 3.6 27B | Difference |
| --- | ---: | ---: | ---: |
| Terminal Bench 2.1 | 73.0 | 63.4 | +9.6 points |
| SWE-bench Pro | 61.7 | 53.5 | +8.2 points |
| NL2Repo-Bench | 42.3 | 36.2 | +6.1 points |
| QwenSWEBench | 79.0 | 49.3 | +29.7 points |

Those are Qwen's upstream evaluations under the harnesses described in its model card; they are evidence for selecting the base model, not locally reproduced QwenOC scores.

On a 64 GiB Mac, QwenOC selects Q8_0 and verifies that LM Studio did not silently load a lower-precision variant. The 48 GiB tier uses Q6_K, and the 32 GiB tier uses Q4_K_M so the same 27B base model remains practical with smaller memory budgets. Greater bit depth generally reduces quantization error, but a task-level Q8-versus-Q6-versus-Q4 evaluation has not yet been published for this profile, so QwenOC does not claim a numerical quality uplift from quantization alone.

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
| A fixed Qwen 27B quantization | Uses Q8 on 64 GiB, Q6 on 48 GiB, and Q4 on 32 GiB while verifying the exact choice | A single fixed artifact is simpler to distribute |
| The same Q8 model without MTP | Speculative drafts can reduce sequential target-model work when acceptance is high | Simpler baseline with no speculative overhead; an A/B benchmark is still needed |
| A smaller 7B–14B local model | More model capacity for repository reasoning and long-horizon agent work | Faster generation, lower memory pressure, and easier parallel use |
| A generic OpenCode local-model configuration | Qwen-specific reasoning controls, prompt, compaction, MCP selection, diagnostics, and runtime safeguards | Less opinionated and easier to adapt to unrelated models |
| Multiple local sessions | Stable single-task speed, full context capacity, and no head-of-line queue | Higher aggregate concurrency on machines with more memory bandwidth |
| A frontier cloud coding model | Local source privacy, no inference subscription or per-token charge, no provider rate limit, and operation without inference-network latency | Cloud models may offer higher absolute capability, faster hardware, and managed availability |

The result is a practical range: quality-oriented Q8 local inference where memory permits, the same 27B model at progressively smaller quantizations on 48 GiB and 32 GiB Macs, and responsive generation for sustained coding work—while remaining transparent about which tier has measured evidence.

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

The 48 GiB Q6_K and 32 GiB Q4_K_M tiers are defined and configuration-tested, but have not yet been benchmarked on those physical machines.

## Requirements

- An Apple Silicon Mac
- At least 32 GiB physical memory; 48 GiB and 64 GiB automatically select higher tiers
- Between 22 GiB and 35 GiB free before download, depending on the selected tier
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

1. Verifies Apple Silicon and maps physical memory to the highest supported tier.
2. Installs LM Studio, OpenCode, and `jq` through Homebrew when needed.
3. Confirms that LM Studio supports `--speculative-draft-mtp`.
4. Downloads the exact mapped GGUF variant when needed: Q8_0, Q6_K, or Q4_K_M.
5. Starts the LM Studio API server.
6. Loads the model with MTP and the tier's canonical context.
7. Runs the full doctor check.

If another Qwen 3.8 variant is already selected, the installer opens LM Studio and identifies the mapped source to select under My Models > Qwen3.8 27B > Variants.

## Launch

Double-click `launch-opencode.command` and choose a project folder, or pass a project directly:

```bash
./launch-opencode.command ~/Development/my-project
```

The launcher redetects memory, starts the LM Studio API server when needed, verifies the exact installed and selected model, and reloads an idle dedicated instance when its context or MTP configuration differs. It generates the tier-specific OpenCode model limits at runtime, enforces one OpenCode session for the one-slot model, then starts OpenCode with this repository's configuration and plugin directory.

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
- RAM-to-tier selection and validity of the shared data map
- Exact mapped GGUF installation and LM Studio source selection
- Live tier-specific context, Flash Attention, and `speculative_draft_mtp: true`
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
- Automatic compaction is enabled with pruning and a tier-specific 32,000, 16,384, or 8,192-token reserve.
- The provider uses one 30-minute request deadline. It does not impose a shorter between-chunk SSE deadline while LM Studio is processing a long prompt.

The local plugin applies the model's generation defaults and adds task state, verification evidence, unresolved failures, and the next action to OpenCode's compaction context.

## Detailed performance record

On the tested 64 GiB Q8_0 tier, eight completed MTP generations produced 6,977 tokens:

- Token-weighted generation speed: 13.41 tokens/second
- Median run: 15.80 tokens/second
- Observed range: 12.44–20.15 tokens/second
- Long coding generations: approximately 12.4–13.0 tokens/second
- MTP drafts accepted: 3,813 of 4,134, or 92.24%

Prompt processing is separate from generation. The tested system processed long prompts at approximately 86–130 tokens/second.

## Runtime hygiene

Every hardware tier deliberately runs one OpenCode session against one LM Studio prediction slot. The launcher uses a single-session lock and reports the PID of an existing session instead of creating a competing queue.

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
config/model-tiers.tsv          RAM, quantization, context, output, and disk-space map
opencode.jsonc                  OpenCode provider, model, agent, MCP, and compaction settings
prompts/qwen-local.txt          Qwen-specific coding-agent system prompt
.opencode/plugins/qwen-local.ts Generation and compaction hooks
.opencode/commands/             /finish and /verify commands
```

## Licensing and attribution

The scripts and configuration in this repository are released under the [MIT License](LICENSE).

The model is downloaded separately from [lmstudio-community/Qwen3.8-27B-GGUF](https://huggingface.co/lmstudio-community/Qwen3.8-27B-GGUF), is based on `Qwen/Qwen3.8-27B`, and is distributed under the Apache-2.0 license stated on its model repository. LM Studio and OpenCode retain their respective licenses and trademarks.

QwenOC is an independent community project and is not affiliated with or endorsed by Qwen, OpenCode, or LM Studio.
