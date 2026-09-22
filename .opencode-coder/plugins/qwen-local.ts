import type { Plugin } from "@opencode-ai/plugin"

export const QwenLocalTuning: Plugin = async () => ({
  "chat.params": async (input, output) => {
    const modelID = input.model.id.toLowerCase()
    if (!["lmstudio", "splash"].includes(input.model.providerID) || !modelID.includes("qwen3.8-27b")) return

    // Match the generation settings shipped with the installed model.
    output.temperature = 1.0
    output.topP = 0.95
    output.topK = 20
    output.options.top_k = 20
    const configuredLimit = Number.parseInt(process.env.QWENOC_OUTPUT_LIMIT ?? "32000", 10)
    const outputLimit = Number.isFinite(configuredLimit) ? configuredLimit : 32000
    output.maxOutputTokens = Math.min(output.maxOutputTokens ?? outputLimit, outputLimit)
  },

  "experimental.session.compacting": async (_input, output) => {
    output.context.push(
      "Preserve the user's current acceptance criteria, files changed, decisions made, verification commands and results, unresolved failures, and the next concrete action. Distinguish completed work from unverified work.",
    )
  },
})
