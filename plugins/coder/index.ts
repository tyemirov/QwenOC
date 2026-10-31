import type { Plugin } from "@opencode/plugin"

export default {
  id: "qwenoc.coder",
  async setup(ctx) {
    await ctx.session.hook("compaction", (request) => {
      if (!["lmstudio", "splash"].includes(request.model.providerID)) return
      request.system.push({
        type: "text",
        text: "Preserve the user's current acceptance criteria, files changed, decisions made, verification commands and results, unresolved failures, and the next concrete action. Distinguish completed work from unverified work.",
      })
    })
  },
} satisfies Plugin
