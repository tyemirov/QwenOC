import type { Plugin } from "@opencode/plugin"
import { sanitizeGrammarSchema } from "../../scripts/grammar-schema.mjs"

type SchemaValue = null | boolean | number | string | SchemaValue[] | { [key: string]: SchemaValue }

export default {
  id: "qwenoc.bureaucrat",
  async setup(ctx) {
    await ctx.session.hook("context", (request) => {
      if (!["lmstudio", "splash"].includes(request.model.providerID)) return
      for (const tool of Object.values(request.tools)) {
        tool.input = sanitizeGrammarSchema(tool.input as SchemaValue) as typeof tool.input
      }
    })
    await ctx.session.hook("compaction", (request) => {
      if (!["lmstudio", "splash"].includes(request.model.providerID)) return
      request.system.push({
        type: "text",
        text: "Preserve all pending email drafts (Recipient, Subject, Body), unread email IDs, active Google Sheet cell coordinates and formula structures, synthesized document references, and explicit user confirmations. Never drop draft states during context compaction.",
      })
    })
  },
} satisfies Plugin
