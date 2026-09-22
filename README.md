# QwenOC

QwenOC is a portable local-coding profile for OpenCode, LM Studio, and Qwen 3.8 27B with its bundled Multi-Token Prediction (MTP) head enabled. It detects Apple unified memory at startup and maps the machine to an exact GGUF quantization and context budget.

The profile keeps inference on the Mac, provides a Qwen-specific system prompt and generation tuning, enables automatic context compaction, and connects the Context7 and `gh_grep` MCP servers for current documentation and public-code examples.

For Splash 4-bit inference, use `--backend splash`.
See [Splash setup and validation](docs/splash.md) for installation, both agent launchers, and diagnostics.
The default backend remains LM Studio.

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

The canonical map lives in [`configs/model-tiers.tsv`](configs/model-tiers.tsv). `install.command`, `launch-opencode.command`, and `doctor.command` read the same file every time they start.

| Detected unified memory | Profile | Exact quantization | Context | Output and compaction reserve | Minimum free space before download |
| ---: | --- | --- | ---: | ---: | ---: |
| 64 GiB or more | quality | Q8_0 | 131,072 | 32,000 | 35 GiB |
| 48–63 GiB | balanced | Q6_K | 65,536 | 16,384 | 28 GiB |
| 32–47 GiB | compact | Q4_K_M | 32,768 | 8,192 | 22 GiB |

The launcher verifies the exact downloaded and selected variant before loading it. A machine with multiple installed variants may require one LM Studio source selection; subsequent launches verify that choice and stop with the precise correction if it changes. Machines below 32 GiB are reported as unsupported by the current map.

The quality/Q8_0 tier has measurements from a 64 GiB Mac. Configuration tests cover the balanced and compact tiers. Their throughput and maximum memory use are not measured. Software validation is sufficient for acceptance.

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

Configuration tests cover the 48 GiB Q6_K and 32 GiB Q4_K_M tiers. These tests do not measure inference speed.

## Requirements

- An Apple Silicon Mac
- At least 32 GiB physical memory; 48 GiB and 64 GiB automatically select higher tiers
- Between 22 GiB and 35 GiB free before download, depending on the selected tier
- [Homebrew](https://brew.sh/)
- Internet access during installation, Google authorization, and configured MCP use

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
7. Runs the full live-runtime doctor check.

If another Qwen 3.8 variant is already selected, the installer opens LM Studio and identifies the mapped source to select under My Models > Qwen3.8 27B > Variants.

## Launch

Launch the agent tailored to your current workflow:

### 💻 Qwen The Coder
Double-click `launch-coder.command` (or `launch-opencode.command`) and choose a project folder, or pass a project directly:

```bash
./launch-coder.command ~/Development/my-project
```

- Tuned for software engineering, repository navigation, LSP, and automated testing.
- Includes Context7 and `gh_grep` documentation and public-code search tools.
- `launch-opencode.command` delegates to this launcher, including the same model and
  server cleanup after OpenCode exits.

### 🗄️ Qwen The Bureaucrat
Double-click `launch-bureaucrat.command` and choose your office workspace directory:

```bash
./launch-bureaucrat.command ~/Documents/OfficeWorkspace
```

- Tuned for executive assistance, Gmail correspondence, Google Drive document organization, and Google Sheets tabular modeling.
- Gated safety permissions: draft creation is automatic, but sending emails or deleting records always requires explicit human confirmation.
- Authorizes Gmail with `gmail.modify`; the Drive MCP requests `drive`,
  `documents`, and `spreadsheets`, plus `openid` and account-email identity scopes
  used to label connected accounts. It does not request Gmail settings, Google
  Slides, or Calendar access.
- Browser tools reuse the existing Chrome Stable session, including its open tabs
  and authenticated state.

#### Existing Chrome Session Setup

Chrome can be launched normally; do not add command-line flags. Before launching
Bureaucrat for the first time:

1. Use Chrome 144 or newer.
2. In the running Chrome instance, open `chrome://inspect/#remote-debugging` and
   enable **Remote Debugging**.
3. Launch Bureaucrat. When Chrome asks whether to allow the debugging connection,
   click **Allow**.

The launcher verifies the Chrome version, running process, and remote-debugging
marker before loading the model. Reusing the personal browser session gives the
agent access to its open tabs, cookies, local storage, and signed-in accounts;
enable this only for a trusted agent.

#### Google Workspace authentication

Bureaucrat uses a local **Desktop OAuth 2.0 Client ID**. Its `gmail.modify` and
full-Drive scopes are restricted; the Docs and Sheets scopes are sensitive. The
`gcloud` CLI is optional because the complete setup is available in the web console.

1. **Configure one Google Cloud project**:
   - Create or select a project in the [Google Cloud Console](https://console.cloud.google.com/).
   - Under **APIs & Services > Library**, enable the **Gmail API**, **Google Drive
     API**, **Google Sheets API**, and **Google Docs API**.
   - In **Google Auth Platform > Branding**, enter an app name such as
     `Bureaucrat`, a user-support email address, and a developer-contact email address.
   - In **Audience**, select **Internal** for an eligible Workspace organization or
     **External** for other Google accounts. For an External app in **Testing**, add
     every account that will authorize Bureaucrat under **Test users**.
   - In **Data Access**, add these Workspace data scopes:
     `https://www.googleapis.com/auth/gmail.modify`,
     `https://www.googleapis.com/auth/drive`,
     `https://www.googleapis.com/auth/documents`, and
     `https://www.googleapis.com/auth/spreadsheets`. The Drive MCP also requests
     standard `openid` and `userinfo.email` identity scopes so it can distinguish
     connected accounts.

2. **Download the desktop client key**:
   - Open **APIs & Services > Credentials**, select **Create credentials > OAuth
     client ID**, and choose **Desktop app**.
   - Download the JSON file. Leave the generated `client_secret_*.json` file in
     `~/Downloads`, or save it as `~/.gmail-mcp/gcp-oauth.keys.json`.
   - Each user must create their own desktop client key. The launcher copies keys
     only between the two user-local MCP directories and never into this repository.

3. **Complete both authorization flows**:
   - Run `./launch-bureaucrat.command`.
   - The launcher validates and copies the desktop key to both MCP configuration
     directories. It then opens separate consent flows for Gmail and Google Drive.
   - Approve both flows. Gmail stores its token in
     `~/.gmail-mcp/credentials.json`; Drive, Docs, and Sheets store theirs in
     `~/.config/google-drive-mcp/tokens.json`. Both files remain local and are
     created with user-only permissions by their MCP servers.
   - Treat the client key and token files as secrets. Repository ignore rules cover
     their standard filenames as a second layer of protection.

4. **Verify the connected accounts**:
   - In Bureaucrat, run `/connect` to inspect and select the effective Drive account.
   - Verify Gmail separately with a harmless read request, such as asking Bureaucrat
     to count messages received today. Drive status does not prove Gmail access.

Google [expires each test user's authorization after seven days](https://support.google.com/cloud/answer/15549945)
for External apps in **Testing**.
The MCP servers refresh valid tokens automatically, but revoked, expired, or
scope-changed authorizations require a new consent flow. Reauthorize both MCPs, or
one of them, without launching the model. Drive reauthorization covers every
account alias already stored by its MCP:

```bash
./launch-bureaucrat.command --reauthorize
./launch-bureaucrat.command --reauthorize gmail
./launch-bureaucrat.command --reauthorize drive
```

Moving an External app to **In production** removes the seven-day Testing expiry;
Google may require verification for the requested sensitive and restricted scopes.
On normal startup, the launcher compares every saved grant with this exact scope
contract and requests re-consent when it finds an older or broader grant.

When an OpenCode session ends, the launcher automatically unloads the heavy Qwen model from unified memory (and stops the background LM Studio server if it was started by the launcher), immediately releasing all system resources.

## Verify the installation

Run diagnostics against this profile alone:

```bash
./doctor.command
```

Run diagnostics against the configuration as resolved inside a specific project:

```bash
./doctor.command ~/Development/my-project
```

The default doctor is non-destructive. If LM Studio is stopped, it verifies the
installation and configuration and reports the skipped live-model check as
information. To require an already running API and the exact loaded MTP model:

```bash
./doctor.command --require-live ~/Development/my-project
```

The doctor never starts, loads, unloads, or stops LM Studio. The installer uses
`--require-live` after its own start/load sequence; runtime launchers retain
ownership of starting and cleaning up their sessions.

The doctor checks:

- Host architecture and memory
- Required command-line tools and minimum OpenCode version
- RAM-to-tier selection and validity of the shared data map
- Exact mapped GGUF installation and LM Studio source selection
- Live tier-specific context, Flash Attention, and `speculative_draft_mtp: true`
  when the runtime is available or `--require-live` is selected
- Resolved OpenCode model, agent, compaction, and MCP settings
- Saved Gmail and every Drive account authorization against the exact scope contract
- Live Context7 and `gh_grep` connections
- Live Bureaucrat Gmail, Drive, and Chrome MCP transport initialization; verify the
  effective Drive identity with `/connect` and Gmail with a safe read request

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
launch-coder.command            Launcher for Qwen The Coder (primary coding agent)
launch-bureaucrat.command       Launcher for Qwen The Bureaucrat (Gmail, Drive, Sheets)
launch-opencode.command         Alias for launch-coder.command (including cleanup)
doctor.command                  Non-destructive configuration audit
scripts/profile.sh              Canonical model and runtime contract
configs/model-tiers.tsv          RAM, quantization, context, output, and disk-space map
configs/coder.jsonc              Dedicated OpenCode configuration for The Coder
configs/bureaucrat.jsonc         Dedicated OpenCode configuration for The Bureaucrat
opencode.jsonc                  Base OpenCode settings
prompts/qwen-local.txt          Qwen-specific coding-agent system prompt
prompts/qwen-bureaucrat.txt     Qwen-specific office and administrative system prompt
.opencode-coder/                Coder-isolated plugins, commands, and skills
.opencode-bureaucrat/           Bureaucrat-isolated plugins, commands, and skills
```

## Licensing and attribution

The scripts and configuration in this repository are released under the [MIT License](LICENSE).

The model is downloaded separately from [lmstudio-community/Qwen3.8-27B-GGUF](https://huggingface.co/lmstudio-community/Qwen3.8-27B-GGUF), is based on `Qwen/Qwen3.8-27B`, and is distributed under the Apache-2.0 license stated on its model repository. LM Studio and OpenCode retain their respective licenses and trademarks.

QwenOC is an independent community project and is not affiliated with or endorsed by Qwen, OpenCode, or LM Studio.
