// @ts-check
import { spawn } from "node:child_process"
import { readFile, access } from "node:fs/promises"
import { homedir } from "node:os"
import { resolve, join, relative, isAbsolute } from "node:path"
import { createInterface } from "node:readline"

export function governorSkill() {
  return process.env.MPRLAB_GOVERNOR_SKILL ?? join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "opencode", "skills", "mprlab-governor")
}

/** @param {string} repo */
export async function requiresSte(repo) {
  const policy = join(repo, ".mprlab", "POLICY.md")
  try {
    await access(policy)
  } catch (error) {
    if (/** @type {NodeJS.ErrnoException} */ (error).code === "ENOENT") return false
    throw error
  }
  return /^\s*(?:-\s*)?(?:Write .+ in|Use) ASD-STE100\b/im.test(await readFile(policy, "utf8"))
}

/** @param {string} repo @param {string} tool @param {unknown} input */
export function editedMarkdownPaths(repo, tool, input) {
  if (typeof input !== "object" || input === null) return []
  const value = /** @type {Record<string, unknown>} */ (input)
  /** @type {string[]} */
  let paths = []
  if (["edit", "write"].includes(tool) && typeof value.path === "string") paths = [value.path]
  if (tool === "patch" && typeof value.patchText === "string") {
    paths = [...value.patchText.matchAll(/^\*\*\* (?:Add File|Update File|Move to): (.+)$/gm)].map(match => match[1])
  }
  return [...new Set(paths.map(path => resolve(repo, path)).filter(path => {
    const local = relative(repo, path)
    return path.endsWith(".md") && local !== ".." && !local.startsWith("../") && !isAbsolute(local)
  }))]
}

/** @param {string} repo @param {string} skill */
export async function prepareSte(repo, skill) {
  const child = spawn("uv", ["run", "--script", join(skill, "scripts", "ste.py"), "prepare", "--repo", repo, "--json"], { cwd: repo, stdio: ["ignore", "pipe", "pipe"] })
  let stdout = "", stderr = ""
  child.stdout.on("data", chunk => { stdout += chunk })
  child.stderr.on("data", chunk => { stderr += chunk })
  const code = await new Promise((accept, reject) => { child.once("error", reject); child.once("close", accept) })
  if (code !== 0) throw new Error(`Prepare STE reference for ${repo}: ${stderr || stdout}`)
  const result = JSON.parse(stdout)
  if (result.status !== "prepared") throw new Error(`STE reference preparation failed for ${repo}`)
}

/**
 * @param {{repo:string, paths?:string[], skill?:string, generate:(prompt:string)=>Promise<string>}} options
 * @returns {Promise<Record<string, any>>}
 */
export async function runAssist({ repo, paths = [], skill = governorSkill(), generate }) {
  const child = spawn("uv", ["run", "--script", join(skill, "scripts", "ste.py"), "assist", ...paths, "--repo", repo, "--changed", "--apply", "--json"], { cwd: repo, stdio: ["pipe", "pipe", "pipe"] })
  let stderr = ""
  child.stderr.on("data", chunk => { stderr = (stderr + chunk).slice(-16000) })
  const completion = new Promise(resolve => {
    child.once("error", error => resolve({ error, code: null }))
    child.once("close", code => resolve({ error: null, code }))
  })
  /** @type {Record<string, any>|undefined} */
  let result
  try {
    for await (const line of createInterface({ input: child.stdout })) {
      const event = JSON.parse(line)
      if (event.type === "request") {
        if (typeof event.id !== "string" || typeof event.prompt !== "string") throw new Error("Invalid STE correction request")
        const text = await generate(event.prompt)
        if (typeof text !== "string") throw new Error("The model did not return text for STE correction")
        child.stdin.write(JSON.stringify({ id: event.id, text }) + "\n")
      } else if (event.type === "result") {
        result = event
      } else {
        throw new Error("Unexpected STE protocol event")
      }
    }
    const finished = await completion
    if (finished.error) throw finished.error
    if (!result || finished.code === null || finished.code > 2) throw new Error(`STE correction failed for ${repo}: ${stderr}`)
    return result
  } catch (error) {
    child.stdin.end()
    child.kill("SIGTERM")
    await completion
    throw new Error(`STE correction for ${repo}: ${/** @type {Error} */ (error).message}`)
  } finally {
    child.stdin.end()
  }
}

/** @param {Record<string, any>} report */
export function assistSummary(report) {
  return {
    status: report.status,
    corrected: (report.passages ?? []).filter(/** @param {any} item */ item => item.status === "applied").length,
    remaining: (report.passages ?? []).filter(/** @param {any} item */ item => !["applied", "proposed"].includes(item.status)).map(/** @param {any} item */ item => ({ path: item.path, line: item.line, status: item.status, reasons: item.reasons, proposal: item.proposal })),
    error: report.error,
    review_completed: false,
  }
}
