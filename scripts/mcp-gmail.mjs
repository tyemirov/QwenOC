#!/usr/bin/env node

/**
 * Transparent stdio wrapper for @artymclabin/gmail-mcp
 * Filters high-value core office tools and sanitizes JSON schemas for llama.cpp/LM Studio GBNF compatibility.
 */

import { spawn } from "child_process";
import readline from "readline";

const UPSTREAM_PKG = "@artymclabin/gmail-mcp";

// Selected core tools for Bureaucrat office workflow
const ALLOWED_TOOLS = new Set([
  "search_emails",
  "read_email",
  "get_thread",
  "list_inbox_threads",
  "get_inbox_with_threads",
  "draft_email",
  "send_email",
  "send_draft",
  "update_draft",
  "delete_draft",
  "modify_email",
  "modify_thread",
  "batch_modify_emails",
  "list_email_labels",
  "create_label",
  "update_label",
  "delete_label",
  "get_or_create_label",
  "download_attachment"
]);

function sanitizeSchema(schema) {
  if (!schema || typeof schema !== "object") return schema;
  if (Array.isArray(schema)) return schema.map(sanitizeSchema);

  const sanitized = {};
  for (const [k, v] of Object.entries(schema)) {
    // Strip non-standard regex and constraints that crash llama.cpp grammar compiler
    if (k === "pattern" || k === "$schema" || k === "additionalProperties") {
      continue;
    }
    sanitized[k] = sanitizeSchema(v);
  }

  // Ensure object types have valid properties
  if (sanitized.type === "object" && (!sanitized.properties || Object.keys(sanitized.properties).length === 0)) {
    sanitized.properties = { _placeholder: { type: "string", description: "Optional parameter" } };
  }

  return sanitized;
}

const child = spawn("npx", ["-y", UPSTREAM_PKG], {
  stdio: ["pipe", "pipe", "inherit"],
  env: process.env
});

const rl = readline.createInterface({ input: child.stdout });

rl.on("line", (line) => {
  if (!line.trim()) return;
  try {
    const msg = JSON.parse(line);
    // Intercept tools/list response to filter and sanitize schemas
    if (msg.result && Array.isArray(msg.result.tools)) {
      msg.result.tools = msg.result.tools
        .filter((t) => ALLOWED_TOOLS.has(t.name))
        .map((t) => ({
          ...t,
          inputSchema: sanitizeSchema(t.inputSchema)
        }));
    }
    process.stdout.write(JSON.stringify(msg) + "\n");
  } catch (e) {
    process.stdout.write(line + "\n");
  }
});

process.stdin.on("data", (chunk) => {
  child.stdin.write(chunk);
});

child.on("exit", (code) => {
  process.exit(code ?? 0);
});
