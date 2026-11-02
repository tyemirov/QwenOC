# QwenOC

![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue)
![Platform: Apple Silicon](https://img.shields.io/badge/platform-Apple%20Silicon-orange)
![Model: Qwen 3.8 27B](https://img.shields.io/badge/model-Qwen%203.8%2027B-green)

QwenOC is a local coding profile for OpenCode, LM Studio, and Qwen 3.8 27B. It uses the Multi-Token Prediction (MTP) head included with the model. When QwenOC starts, it reads the Apple unified memory and sets the correct GGUF quantization and context limit.

The profile keeps inference on the Mac. It gives a system prompt for Qwen and generation control. It uses automatic context compaction. It connects the Context7 and `gh_grep` MCP servers for documentation and open-code examples.

For Splash inference, use `--backend splash`. Splash selects 8-bit weights on Macs with 64 GiB or more of unified memory and 4-bit weights on the other Macs with less memory. See [Splash install and validation](docs/splash.md) for the install, the agent launchers, and diagnostics. The profile uses LM Studio unless you select Splash.

## First steps

Get the repository and start `install.command`:

```bash
git clone https://github.com/tyemirov/QwenOC.git
cd QwenOC
./install.command
```

`install.command` installs LM Studio, OpenCode, and the model. It selects the correct tier from your unified memory and loads the model with MTP.

## Contents

- [Necessary items](#necessary-items)
- [Install](#install)
- [Start the agents](#start-the-agents)
  - [Qwen The Coder](#qwen-the-coder)
  - [Qwen The Bureaucrat](#qwen-the-bureaucrat)
- [Verify the installation](#verify-the-installation)
- [Agent controls](#agent-controls)
- [Simplified Technical English](#simplified-technical-english)
- [Runtime limits](#runtime-limits)
- [Adjustments and network](#adjustments-and-network)
- [Security](#security)
- [Repository contents](#repository-contents)
- [Licensing](#licensing)
- [Why this structure](docs/why.md)

## Necessary items

- An Apple Silicon Mac
- 32 GiB or more of unified memory. 48 GiB and 64 GiB select the next tier.
- 22 GiB to 35 GiB of free space before you get the model, by tier
- [Homebrew](https://brew.sh/)
- Internet access during the install, Google authorization, and MCP use

## Install

Get the repository, move to it, and start `install.command`:

```bash
git clone https://github.com/tyemirov/QwenOC.git
cd QwenOC
./install.command
```

Start `install.command` as many times as necessary. It:

1. Checks the Mac for Apple Silicon and selects the tier from the unified memory.
2. Installs LM Studio, OpenCode through `anomalyco/tap/opencode-v2`, and `jq` when necessary.
3. Makes sure that LM Studio can use `--speculative-draft-mtp`.
4. Gets the correct GGUF quantization for the tier when necessary: Q8_0, Q6_K, or Q4_K_M.
5. Starts the LM Studio API server.
6. Loads the model with MTP and the tier context.
7. Does the full live-runtime doctor check.

If a different Qwen 3.8 quantization is selected, `install.command` opens LM Studio. It identifies the source to select in My Models > Qwen3.8 27B > Variants.

## Start the agents

Start the agent for your work:

### Qwen The Coder

Open `launch-coder.command` (or `launch-opencode.command`) and select a project location, or start the launcher with a project:

```bash
./launch-coder.command ~/Development/my-project
```

- Works on coding, repository work, LSP, and automatic tests.
- Includes Context7 and `gh_grep` for documentation and open-code examples.
- `launch-opencode.command` uses this launcher. Each launcher uses the same model. The launcher removes the model and stops the server after OpenCode exits.

### Qwen The Bureaucrat

Open `launch-bureaucrat.command` and select your work location:

```bash
./launch-bureaucrat.command ~/Documents/OfficeWorkspace
```

- Works on Gmail, Google Drive, and Google Sheets.
- The agent makes drafts. It sends an email or removes a record only after a person check.
- The profile uses the `gmail.modify` scope for Gmail. The Drive MCP uses the `drive`, `documents`, and `spreadsheets` scopes, plus `openid` and `userinfo.email`. It uses these scopes to label the accounts. It does not use the Gmail adjustments, Google Slides, or Calendar access.
- The Chrome tools use the open Chrome Stable session. The agent can read the session data and use the accounts in the session.

Do the Chrome session and Google Workspace authorization before the first start. See [Bureaucrat install](docs/bureaucrat-setup.md).

When an OpenCode session ends, the launcher removes the Qwen model from unified memory and stops the LM Studio server if it started it.

## Verify the installation

Start the diagnostics for this profile:

```bash
./doctor.command
```

Start the diagnostics against the adjustments in a selected project:

```bash
./doctor.command ~/Development/my-project
```

The doctor does not change the installation. If LM Studio is stopped, it verifies the installation and adjustments and reports that it did not do the live-model check. To make sure that the live API and the correct MTP model are available:

```bash
./doctor.command --require-live ~/Development/my-project
```

The doctor does not start, load, or stop LM Studio. `install.command` uses `--require-live` after it starts and loads. The runtime launchers start and clean up their sessions.

The doctor checks:

- Mac architecture and unified memory
- Necessary commands and minimum OpenCode release
- RAM-to-tier selection and the tier data
- Correct GGUF installation and LM Studio source selection
- Live tier context, Flash Attention, and `speculative_draft_mtp: true` when the runtime is available or `--require-live` is selected
- OpenCode model, agent, compaction, and MCP adjustments in the project
- Gmail and each Drive account authorization against the correct scope contract
- Live Context7 and `gh_grep` connections
- Live Bureaucrat Gmail, Drive, and Chrome MCP transport start. Verify the Drive account with `/connect`. Verify Gmail with a safe read request.

The launcher also gives the same check:

```bash
./launch-opencode.command --doctor ~/Development/my-project
```

## Agent controls

- `qwen-local` is the primary agent.
- Push `Ctrl+T` in OpenCode to cycle the reasoning effort: `low`, `medium`, or `xhigh`. `medium` is the primary value.
- Start `/finish` to continue a task until it obeys its acceptance criteria and tests.
- Start `/verify` for the last repository changes and a test check.
- Automatic compaction uses `compaction.buffer` with a 32,000, 16,384, or 8,192-token limit for the selected tier.
- The provider uses one 30-min request limit. It does not set a short SSE limit for a long request.

The model request sets the generation. The source code in `plugins/coder/` adds the task, the test results, the open failures, and the next step to the compaction context.

## Simplified Technical English

Use `/ste` to correct selected changed Markdown files through the native `ste_assist` tool.
Install both `ste-writing` and `mprlab-governor` through the Smith skill installer.

The Coder host prepares the reference before Markdown edits when the repository policy requires STE.
After each edit, it runs bounded correction attempts with the selected model.
Each request contains one prose block, specific findings, and relevant reference excerpts.
The host preserves protected literals and returns meaning changes as unapplied proposals.
Review these proposals against their source before correction.

The shared review and lookup commands inspect source without edits.
The assist command can apply accepted corrections.
A mechanical pass leaves the remaining language review to the producing agent.

```bash
make docs
make docs MPRLAB_GOVERNOR_SKILL=/path/to/mprlab-governor
```

The default skill path is under the global OpenCode configuration directory.
The `docs` target examines changed prose relative to `HEAD`, including new Markdown files.
The `ci` target includes this check.
For a complete document review, use the shared command with explicit file paths.

## Runtime limits

Each tier uses one OpenCode session and one LM Studio inference slot. The launcher uses a one-session lock. It reports the PID of the open session and does not start a new session.

If OpenCode reports `SSE read timed out`, close the open profile session and start it again through `launch-opencode.command`. The doctor reports more than one open profile session as a failure.

The profile does not load skills from `.claude/skills`. A skill in `.agents/skills` or the `.opencode/skills` location of this profile loads one time only.

## Adjustments and network

OpenCode reads adjustments from the launcher, the Mac, and the project. The launcher adjustments override the Mac and project adjustments. Each launcher uses `--standalone` with the selected model and agent in `OPENCODE_CONFIG_CONTENT`. The doctor reads the v2 source data and verifies the model, agent, compaction limit, and MCP adjustments. An organization config can override all the other adjustments.

QwenOC connects to the local LM Studio API at `http://127.0.0.1:1234`. OpenCode keeps sessions local. Context7 and `gh_grep` make network requests when used.

## Security

QwenOC keeps inference on the Mac. It connects to the local LM Studio API at `http://127.0.0.1:1234`. OpenCode keeps sessions local.

Context7 and `gh_grep` make network requests when used. The Bureaucrat connects to Google with the scopes in the contract. See [Bureaucrat install](docs/bureaucrat-setup.md) for the scope contract.

The launcher uses the open Chrome session for the Bureaucrat. That session gives the agent access to its data, local storage, and the accounts in the session. Use this only for an agent that you control.

Send security reports to [support@mprlab.com](mailto:support@mprlab.com). Do not open an issue for a security problem. See [SECURITY.md](SECURITY.md) for the report steps.

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
.opencode-coder/                Coder commands and skills
.opencode-bureaucrat/           Bureaucrat commands and skills
plugins/coder/                  Native v2 Coder source code
plugins/bureaucrat/             Native v2 Bureaucrat source code
```

## Licensing

The license for the code and adjustments in this repository is the [PolyForm Noncommercial License 1.0.0](LICENSE). Commercial use is not in the license. For commercial use, contact legal@mprlab.com. See [COMMERCIAL_LICENSE.md](COMMERCIAL_LICENSE.md).

You get the model from [lmstudio-community/Qwen3.8-27B-GGUF](https://huggingface.co/lmstudio-community/Qwen3.8-27B-GGUF). The model comes from `Qwen/Qwen3.8-27B` with the Apache-2.0 license on its model repository. LM Studio and OpenCode keep their licenses.

QwenOC is a project by its contributors. It has no connection to Qwen, OpenCode, or LM Studio.

For contributions, see [CONTRIBUTING.md](CONTRIBUTING.md) and [CONTRIBUTOR_LICENSE.md](CONTRIBUTOR_LICENSE.md).
