# Splash inference

QwenOC selects a Splash model from the physical memory at each start.
The model map is [`configs/splash-models.json`](../configs/splash-models.json).

| Unified memory | Model | Quantization |
| --- | --- | --- |
| 64 GiB or more | `unsloth/Qwen3.8-27B-GGUF:Q8_0` | 8-bit |
| 36–63 GiB | `incoai/Qwen3.8-27B-Splash` | 4-bit |

Both models use DFlash 2.
The Q8_0 target weights require approximately 27.1 GiB, plus the draft, vision weights, and prepared cache.
Splash sets the context limit from available memory at startup.
The 4-bit package contains the target weights, draft, vision encoder, and tokenizer.
The LM Studio model map remains separate.

The [Splash README](https://github.com/incoai/splash) defines the runtime interface.
The [model card](https://huggingface.co/incoai/Qwen3.8-27B-Splash) describes the package.
The [GGUF documentation](https://github.com/incoai/splash/blob/main/DEVELOPMENT.md#gguf-targets) lists Q8_0 support.
QwenOC selects `Q8_0` for the 64 GiB profile.

As of September 25, 2026, direct GGUF support is on upstream `main` and awaits the release after 1.0.2.
The installed CLI must advertise GGUF support in `splash serve --help` before QwenOC starts a Q8_0 model.
An older CLI produces an upgrade error.
An existing ready server with the exact Q8_0 model can operate without a local CLI upgrade.

## Requirements

Splash requires Apple M3 or newer, macOS 26.4 or later, and at least 36 GB of unified memory.
Inco recommends at least 48 GB. The 4-bit package download is approximately 17.4 GB.
The installer requires Homebrew and internet access.
Splash checks its runtime requirements and available memory at startup.

These requirements describe the runtime. They do not require physical devices for development or acceptance.

## Install and launch

For Q8_0, first install a Splash build with direct GGUF support.
Until the next release, follow the upstream [source build instructions](https://github.com/incoai/splash/blob/main/DEVELOPMENT.md#build-and-run).
Add that build directory to `PATH` before the Homebrew directories.
Check that `splash serve --help` describes GGUF model variants.
The QwenOC installer installs the Homebrew formula when Splash is absent.
It does not build upstream `main` or upgrade an existing installation.

1. Run the installer:

   ```bash
   bash install.command --backend splash
   ```

   The installer installs missing Splash, OpenCode, Node.js, and jq dependencies.
   Splash downloads and prepares the selected model and draft on the first run.
   The installer checks the runtime and both agent configurations.
   It stops the server if it started that server.

2. Launch the required agent:

   ```bash
   bash launch-coder.command --backend splash ~/Development/my-project
   bash launch-bureaucrat.command --backend splash ~/Documents/OfficeWorkspace
   ```

   Bureaucrat retains its Google authorization and Chrome requirements.
   `launch-opencode.command` also accepts `--backend splash`.
   The default backend remains LM Studio.

## Runtime behavior

If Splash is missing, the launcher installs it through Homebrew.
Bureaucrat completes this check before Google setup.

The launcher starts Splash if the selected port has no HTTP server.
The first startup can take up to 30 minutes for the download and initialization.
The launcher writes Splash output to a separate file in `~/Library/Logs/QwenOC/`.
It prints the log path before startup and keeps the file after the session.
Splash output cannot interrupt the OpenCode display.
If startup fails, the last 80 log lines appear in the terminal.
The launcher checks readiness, the exact model ID, and the reported context limit before it starts OpenCode.
If an existing server has the wrong model or credentials, the launcher stops with an error.

QwenOC uses the server context limit for OpenCode.
The output allowance is one quarter of that limit, with a maximum of 32,768 tokens.
The input allowance is the context limit minus the output allowance.
The compaction reserve equals the output allowance.
The main model, auxiliary model, and selected agent use Splash.

The reasoning variants are `none`, `low`, `medium`, and `xhigh`.
Coder starts with `medium`. Bureaucrat starts with `low`.
Both agents use `top_k=20` with Splash. Splash 1.0 accepts values from 1 to 32.

QwenOC uses the OpenAI-compatible Chat Completions API and preserves the existing role tools and prompts.
Splash provides DFlash 2 speculative decoding. The LM Studio MTP options do not apply.

The local backends share a session lock.
When OpenCode exits, the launcher stops only the Splash process that it started.
A server that was already active remains active.
The OpenCode exit status remains available to the caller.

## Port, authentication, and cache

The endpoint is `http://127.0.0.1:8000/v1`.
QwenOC uses port 8000 for both Splash model profiles.
New Splash builds have port options, but QwenOC keeps this endpoint fixed.
If you previously set `SPLASH_PORT`, remove it with `unset SPLASH_PORT` before launch.
If another service uses port 8000, stop that service before launch.
QwenOC reports the conflict and does not stop that service.

To use authentication, set `SPLASH_API_KEY` in the shell before setup or launch.
An existing server and the launcher must use the same key.
QwenOC references the environment variable in its OpenCode configuration.
It does not save the key in repository configuration files.

Splash owns its downloads and model cache.
Set `HF_HUB_CACHE` before the first run to select another cache directory.

## Diagnostics and validation

Run the read-only configuration check:

```bash
bash doctor.command --backend splash
```

If Splash is stopped, this command reports the skipped live check.
To require an active server, use:

```bash
bash doctor.command --backend splash --require-live ~/Development/my-project
```

The doctor checks readiness, model identity, context limits, and both resolved agent configurations.
It does not start a server or send an inference request.
It does not qualify Google authorization or Chrome connections in Splash mode.
The Bureaucrat launcher retains those checks before an agent session.

Run the repository checks with `make ci`. The test command requires `uv`.
The tests use the public shell commands, a local HTTP protocol server, and controlled external CLI responses.
Simulated memory values verify Q8_0 selection at 64 GiB and 96 GiB, plus the 4-bit selection below 64 GiB.
The tests also check the older CLI error and rejection of a different active model.
They cover configuration, authentication, model rejection, context limits, process ownership, and exit status.
The protocol tests do not measure actual Splash generation quality, throughput, or memory use.

OpenCode 1.18.31 also passed a separate streamed-response check against the local HTTP protocol server.
That check verified the model ID, `reasoning_effort`, `top_k`, and response text.
The new guide passed the mechanical language check. Existing README language findings remain outside the changed text.
The Governor check reports existing policy and guide drift, plus a missing Python guide.
These governance findings do not indicate a Splash runtime test failure.

The current backend choices are `local` and `splash`.
Before implementation, the launcher integration test failed with `Unknown backend: splash`.
