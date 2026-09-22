import type { Plugin } from "@opencode-ai/plugin"

function sanitizeGrammarSchema(schema: any): any {
  if (!schema || typeof schema !== "object") return schema
  if (Array.isArray(schema)) return schema.map(sanitizeGrammarSchema)

  const sanitized: Record<string, any> = {}
  for (const [key, value] of Object.entries(schema)) {
    // Strip regex patterns and non-standard JSON schema fields that crash llama.cpp grammar compiler
    if (key === "pattern" || key === "$schema" || key === "additionalProperties") {
      continue
    }
    sanitized[key] = sanitizeGrammarSchema(value)
  }
  return sanitized
}

export const QwenBureaucratTuning: Plugin = async () => ({
  "chat.params": async (input, output) => {
    const modelID = input.model.id.toLowerCase()
    if (!["lmstudio", "splash"].includes(input.model.providerID) || !modelID.includes("qwen3.8-27b")) return

    // Deterministic, low-temperature parameters for administrative accuracy & formal correspondence
    output.temperature = 0.5
    output.topP = 0.9
    // Splash 1.0 accepts at most 32 candidates; use its default of 20.
    const topK = input.model.providerID === "splash" ? 20 : 40
    output.topK = topK
    output.options.top_k = topK
    const configuredLimit = Number.parseInt(process.env.QWENOC_OUTPUT_LIMIT ?? "32000", 10)
    const outputLimit = Number.isFinite(configuredLimit) ? configuredLimit : 32000
    output.maxOutputTokens = Math.min(output.maxOutputTokens ?? outputLimit, outputLimit)
  },

  "tool.definition": async (_input, output) => {
    if (output.parameters) {
      output.parameters = sanitizeGrammarSchema(output.parameters)
    }
  },

  "experimental.session.compacting": async (_input, output) => {
    output.context.push(
      "Preserve all pending email drafts (Recipient, Subject, Body), unread email IDs, active Google Sheet cell coordinates and formula structures, synthesized document references, and explicit user confirmations. Never drop draft states during context compaction.",
    )
  },
})
