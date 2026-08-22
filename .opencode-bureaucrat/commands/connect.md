---
description: Check or request Google Workspace account connection status
agent: qwen-bureaucrat
subtask: false
---

Call `google_drive_manage_accounts` with `action: "list"`, then call
`google_drive_authGetStatus` to inspect the effective Google Drive identity and
authorization health.

- If one account or a default account is connected, report its alias and identity.
- If multiple accounts are connected without a default, list their aliases and ask
  which one to select. After the user answers, call `google_drive_manage_accounts`
  with `action: "set_default"` and the selected `account_id`.
- If no account is configured, ask the user for a short account alias, then call
  `google_drive_manage_accounts` with `action: "add"` and that `account_id`.
- Report only the exposed Drive, Docs, and Sheets capabilities. Gmail authorization
  is separate and must not be inferred from the Drive account status.
