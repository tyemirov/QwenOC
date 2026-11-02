# Why this structure

QwenOC gives a person a coding agent that works on the Mac. It does not select the smallest model or the fastest generation rate alone. It selects the maximum precision for the available unified memory. It increases generation speed with MTP speculative decoding and the Apple Silicon runtime.

## The parts

| Part | QwenOC selection | What it gives |
| --- | --- | --- |
| Model | Qwen 3.8 27B | A model that works on coding, work sequences, tool results, images, and long agent work |
| Precision | Q8_0, Q6_K, or Q4_K_M from the unified memory | It uses the maximum tier for the available unified memory. It does not use the LM Studio selection by itself |
| Decoding | The MTP head that comes with the model | It makes draft tokens. The same model checks them. It gives more speed to the work with the same model |
| Runtime | Full GPU offload, Flash Attention, and context by tier | It uses the unified memory. It sets the context and output limits from the unified memory tier |
| Agent profile | The Qwen system prompt, reasoning effort control, compaction, and control commands | It makes the chat model into a coding work system. It does not use the standard config |
| Tools | Context7 and `gh_grep` only | It adds documentation and open-code search. It does not load a large MCP list |
| Sessions | One OpenCode session and one inference slot | It gives the coding work the full unified memory speed of the Mac. It decreases the number of requests that wait for inference |

## Unified memory profiles

The one table for all tiers is in [`configs/model-tiers.tsv`](../configs/model-tiers.tsv). `install.command`, `launch-opencode.command`, and `doctor.command` read the same table each time they start.

| Unified memory | Profile | Exact quantization | Context | Output and compaction limit | Minimum free space before you get the model |
| ---: | --- | --- | ---: | ---: | ---: |
| 64 GiB or more | quality | Q8_0 | 131,072 | 32,000 | 35 GiB |
| 48–63 GiB | balanced | Q6_K | 65,536 | 16,384 | 28 GiB |
| 32–47 GiB | compact | Q4_K_M | 32,768 | 8,192 | 22 GiB |

The launcher checks the exact quantization before it loads it. If the Mac has many quantizations, a source selection in LM Studio can be necessary. Each start checks that selection. If it changes, the launcher stops and gives the correction. The table has no tier for Macs with less than 32 GiB.

The quality/Q8_0 tier has measurements from a 64 GiB Mac. The tests include the balanced and compact tiers. The tests do not measure the speed or the maximum unified memory use. The software check is sufficient to accept these tiers.

## Quality: Qwen 3.8 27B and adaptive precision

The [upstream Qwen3.8-27B model card](https://huggingface.co/Qwen/Qwen3.8-27B) compares Qwen3.8-27B with Qwen3.6-27B in coding benchmarks.

| Upstream benchmark | Qwen 3.8 27B | Qwen 3.6 27B | Difference |
| --- | ---: | ---: | ---: |
| Terminal Bench 2.1 | 73.0 | 63.4 | +9.6 points |
| SWE-bench Pro | 61.7 | 53.5 | +8.2 points |
| NL2Repo-Bench | 42.3 | 36.2 | +6.1 points |
| QwenSWEBench | 79.0 | 49.3 | +29.7 points |

Qwen made these values with the tests in its model card. They show why QwenOC selects this model. They are not QwenOC values made on this Mac.

On a 64 GiB Mac, QwenOC selects Q8_0. It checks that LM Studio did not load a lower precision. The 48 GiB tier uses Q6_K. The 32 GiB tier uses Q4_K_M. The same 27B model works with less unified memory.

More bits usually decrease the quantization error. No test compares Q8, Q6, and Q4 on tasks for this profile. QwenOC does not give a quality number for quantization alone.

## Speed: what MTP changes

LM Studio calls this method [speculative decoding](https://lmstudio.ai/docs/app/advanced/speculative-decoding). It increases speed with no change in quality. The draft model makes tokens. The model that gives the result checks them. It rejects incorrect tokens.

The MTP steps are part of Qwen3.8-27B. This profile loads the MTP head that comes with the model. It does not load a general draft model.

On the 64 GiB Mac, 8 coding generations show:

- **6,977 tokens** at a token-weighted rate of **13.41 tokens/second**, or approximately **805 tokens/minute**
- **92.24% MTP acceptance**: the model accepts 3,813 of the 4,134 draft tokens
- A middle value of **15.80 tokens/second**, with a measured range of 12.44 to 20.15 tokens/second
- The model reads the prompt at approximately 86 to 130 tokens/second

The high acceptance rate shows that MTP does real speculative work on these coding tasks. This is the end-to-end speed. It is not an MTP speed-up number. QwenOC does not have a test of this GGUF with MTP off on the same work yet.

## What the OpenCode profile adds

The model is only one part of an agent. [OpenCode gives each agent its prompt, model, and generation control](https://opencode.ai/docs/agents/). QwenOC uses that to give:

- The `low`, `medium`, and `xhigh` reasoning effort levels. The model keeps the reasoning in the conversation
- A coding system prompt. It tells the model to examine and change code, do tests, repair errors, and give the test results
- Automatic context compaction with a 32,000-token output limit. It keeps the task condition
- The `/finish` and `/verify` commands for the finish and the last repository check
- A short list of MCP tools for documentation and open-code search
- Exact checks of the model, quantization, MTP, context, and server before the work starts
- A one-session lock and a 30-min request limit for local inference

## Compared with alternatives

| Alternative | What QwenOC gives | What the alternative gives |
| --- | --- | --- |
| A fixed Qwen 27B quantization | It uses Q8 on 64 GiB, Q6 on 48 GiB, and Q4 on 32 GiB. It checks the exact selection | One fixed artifact is simple to move |
| The same Q8 model without MTP | The draft tokens decrease the target model work when acceptance is high | It is simple with no draft work. It does not have an A/B benchmark yet |
| A 7B to 14B local model | More model capacity for repository reasoning and long agent work | Faster generation, less unified memory use, and easy parallel work |
| A general OpenCode local-model config | The Qwen reasoning levels, prompt, compaction, MCP list, diagnostics, and runtime limits | It is less fixed and easy to change for other models |
| Many local sessions | Stable one-task speed, full context capacity, and no requests that wait | More work at the same time on Macs with more unified memory speed |
| A hosted coding model | The source stays on the Mac. No charge by the month, no per-token charge, no provider rate limit, and no network delay | Hosted models can give a stronger model and faster systems. The provider controls the access |

QwenOC gives a range. It uses Q8 local inference when the unified memory is sufficient. It uses the same 27B model with less precision on 48 GiB and 32 GiB Macs. It gives fast generation for long coding work. It shows which tier has the measurements.

## Tested config

- An Apple Silicon Mac with 64 GiB unified memory
- macOS 26.6.2
- LM Studio 0.4.21+2
- LM Studio llama.cpp runtime 2.28.2
- OpenCode 2.2.5 for this config and the CLI integration tests
- Qwen 3.8 27B GGUF Q8_0, approximately 30 GB of storage
- 131,072-token context, full GPU offload, Flash Attention, one inference slot, and one OpenCode session
- MTP speculative decoding with the MTP head from the model. The measured draft-token acceptance rate is 92.24%

The recorded inference measurements used OpenCode 1.18.17. This config uses OpenCode 2.2.5 and its v2 schema. The CLI integration tests use the installed OpenCode and a local HTTP server. The tests include the 2 agents, each tier, and the request data. They do not measure inference speed.

This repository has the config and the code. `install.command` gets the model from LM Studio. The tests include the 48 GiB Q6_K and 32 GiB Q4_K_M tiers. They do not measure inference speed.
