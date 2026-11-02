import type { Plugin } from "@opencode/plugin"
import { assistSummary, editedMarkdownPaths, governorSkill, prepareSte, requiresSte, runAssist } from "../../scripts/ste-assist.mjs"

export default {
  id: "qwenoc.coder",
  async setup(ctx) {
    const models = new Map<string, Parameters<typeof ctx.experimental.generate.text>[0]["model"]>()
    const notices = new Map<string, string[]>()
    const repo = ctx.location.directory
    const skill = governorSkill()
    let prepared = false
    let pending = Promise.resolve()
    const enabled = () => requiresSte(repo)
    const prepare = async () => {
      if (prepared) return
      await prepareSte(repo, skill)
      prepared = true
    }
    const correct = async (sessionID: string, agent: string, paths: string[]) => {
      const model = models.get(sessionID)
      if (!model) throw new Error("STE assistance requires the current session model")
      for (const path of paths) {
        await ctx.permission.assert({ sessionID, agent, action: "edit", resources: [path], save: [path] })
      }
      await prepare()
      return runAssist({ repo, paths, skill, generate: async prompt => (await ctx.experimental.generate.text({ model, prompt })).text })
    }
    const enqueue = (sessionID: string, agent: string, paths: string[]) => {
      const operation = pending.then(() => correct(sessionID, agent, paths))
      // Keep the queue usable after a reported failure. The operation itself still rejects.
      pending = operation.then(() => undefined, () => undefined)
      return operation
    }
    await ctx.tool.transform(editor => {
      editor.add({
        name: "ste_assist",
        description: "Correct mechanical STE errors in selected changed Markdown files. Preserve protected content and report meaning changes for review.",
        input: { type: "object", properties: { paths: { type: "array", items: { type: "string" }, minItems: 1 } }, required: ["paths"], additionalProperties: false },
        options: { codemode: false },
        execute: async (input, context) => {
          const paths = (input as { paths: string[] }).paths.flatMap(path => editedMarkdownPaths(repo, "edit", { path }))
          if (!paths.length) throw new Error("Select Markdown files inside the active repository for STE assistance")
          const report = await enqueue(context.sessionID, context.agent, paths)
          return { content: JSON.stringify(assistSummary(report)) }
        },
      })
    })
    await ctx.session.hook("context", request => {
      models.set(request.sessionID, request.model)
      const notice = notices.get(request.sessionID)
      if (notice) {
        request.system.push({ type: "text", text: notice.join("\n") })
        notices.delete(request.sessionID)
      }
    })
    await ctx.tool.hook("execute.before", async event => {
      if (editedMarkdownPaths(repo, event.tool, event.input).length && await enabled()) await prepare()
    })
    await ctx.tool.hook("execute.after", async event => {
      if (event.status !== "completed") return
      const paths = editedMarkdownPaths(repo, event.tool, event.input)
      if (!paths.length || !await enabled()) return
      let summary
      try {
        summary = assistSummary(await enqueue(event.sessionID, event.agent, paths))
      } catch (error) {
        summary = { status: "error", error: (error as Error).message, review_completed: false }
      }
      notices.set(event.sessionID, [...(notices.get(event.sessionID) ?? []), "STE assistance: " + JSON.stringify(summary)])
    })
    await ctx.session.hook("compaction", (request) => {
      if (!["lmstudio", "splash"].includes(request.model.providerID)) return
      request.system.push({
        type: "text",
        text: "Preserve the user's current acceptance criteria, files changed, decisions made, verification commands and results, unresolved failures, and the next concrete action. Distinguish completed work from unverified work.",
      })
    })
  },
} satisfies Plugin
