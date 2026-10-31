# Delete a Conversation

This runbook deletes one OpenCode conversation and its local residue.
It covers the OpenCode database, the OpenCode log, and the LM Studio server log.
Use this runbook on a Mac that runs OpenCode with a local LM Studio server.
This runbook uses sample values:

- `S`: The session ID of the target.
- `T0`: The start time of the conversation.
- `T1`: The end time of the conversation.
- `START`: The line number of the first deleted server log line.
- `END`: The line number of the last deleted server log line.
- `L`: The location of the server log file.

## Where the Residue Lives

| Location | Holds |
| --- | --- |
| `~/.local/share/opencode/opencode.db` | The session entry and its content entries. |
| `~/.local/share/opencode/log/opencode.log` | Session lines that quote the ID and content. |
| `~/.local/share/opencode/storage` | Per-session files. Usually none. |
| `~/.local/share/opencode/snapshot` | Per-session files. Usually none. |
| `~/.local/share/opencode/tool-output` | Per-session files. Usually none. |
| `~/.lmstudio/server-logs/YYYY-MM/YYYY-MM-DD.N.log` | Full request content when `logSensitiveData` is `true`. |
| `~/.lmstudio/conversations/*.conversation.json` | A copy when a person used the LM Studio UI. |
| `~/Library/Logs/LM Studio/main.log` | Metadata and settings only. |
| `~/.lmstudio/.internal/model-data.json` | Model data and times only. |
| `~/Library/Application Support/LM Studio/` | UI settings only. |
| `~/.Trash`, `/tmp`, `~/.zsh_history` | Usually clean. Examine. |
| The deleting session | Its saved content quotes the target ID. |

## Required Actions

1. Never display the content of the target.
   Work with metadata only: name, location, time, and number.
   Any displayed content lands in the deleting session and its server log.
   This content becomes new residue.
2. Write the new content into the same file. Do this for each live file.
   Do not use a command that changes the file name or moves the file.

   ```bash
   grep -v "$S" "$L" > /tmp/oc.filtered && cat /tmp/oc.filtered > "$L" && rm /tmp/oc.filtered
   ```

   When you change the file name, the process that writes the file keeps the old file open.
   The old file keeps the sensitive lines until the process ends.
3. Build the session ID from fragments inside each command.
   Never enter conversation content in a command.
   The OpenCode log can quote the content of each command.
   This keeps the complete session ID out of the log.
4. Delete the database entries first.
   Delete the server log lines second.
   Delete the OpenCode log lines last.
   The OpenCode log holds the ID lines of your delete commands.
   Verify with fragments of the session ID.
5. Make no copy of the content.
   Delete each output file in the same command that creates it.

## Step 1: Identify the Target

Run the commands below in a terminal.
Select the target by name, location, and time.
Record the session ID as `S`.
Record the conversation start time as `T0` and the end time as `T1`.

```bash
sqlite3 -header -column ~/.local/share/opencode/opencode.db \
 "SELECT id,title,directory,
   datetime(time_created/1000,'unixepoch','localtime') created,
   datetime(time_updated/1000,'unixepoch','localtime') updated
  FROM session ORDER BY time_updated DESC LIMIT 10;"
```

The list shows the sessions with the last update time.
Select the row of the target conversation.
Make sure that no session has a `parent_id` equal to the target ID.

```bash
sqlite3 ~/.local/share/opencode/opencode.db \
 "SELECT id,title FROM session WHERE parent_id='$S';"
```

If the command shows rows, run Step 2 for each row first.
Make sure that the `share_url` of the target session is empty.

```bash
sqlite3 ~/.local/share/opencode/opencode.db \
 "SELECT share_url FROM session WHERE id='$S';"
```

If the `share_url` is not empty, the conversation reached a system outside the Mac.
This runbook cannot remove content that leaves the Mac.
A person must remove that copy from the system outside the Mac.
Make sure that no process of the target runs.

```bash
ps aux | grep -i opencode
```

Only the process of this session must remain.

## Step 2: Delete the Database Entries

Build the session ID from fragments. Run the command below.

```bash
S="ses_0123""abc"
sqlite3 "$HOME/.local/share/opencode/opencode.db" "PRAGMA busy_timeout=20000;
 DELETE FROM part WHERE session_id='$S';
 DELETE FROM message WHERE session_id='$S';
 DELETE FROM session_message WHERE session_id='$S';
 DELETE FROM session_input WHERE session_id='$S';
 DELETE FROM session_share WHERE session_id='$S';
 DELETE FROM session_context_epoch WHERE session_id='$S';
 DELETE FROM event WHERE aggregate_id='$S';
 DELETE FROM event_sequence WHERE aggregate_id='$S';
 DELETE FROM session WHERE id='$S';
 PRAGMA wal_checkpoint(TRUNCATE);
 VACUUM;
 PRAGMA wal_checkpoint(TRUNCATE);"
```

The command deletes the entries of the target session.
The `VACUUM` command rebuilds the file.
The file no longer holds the deleted pages.
The `PRAGMA` command clears the write-ahead log.
That log holds the old pages of the file.
Run this step for each row from Step 1.

## Step 3: Delete the Server Log Lines

Examine the LM Studio settings file first.

```bash
cat ~/.lmstudio/.internal/http-server-config.json
```

If `logSensitiveData` is `false`, the server did not log request content.
Do not run this step.
Open the server log that covers the period.

```bash
ls ~/.lmstudio/server-logs/
```

Set `L` to the server log file that covers the period.

```bash
# Sample value for L. Use the file that covers your period.
L=~/.lmstudio/server-logs/2026-10/2026-10-30.0.log
grep -n "Server started\|Server stopped" "$L"
grep -n "Received request: POST to /v1/chat/completions with body" "$L"
```

The `grep` command shows the line number of each result.
LM Studio can start a new server for each conversation.
The conversation runs inside one start-and-stop period of one server.
Set `START` to the line number of the first log line with a time at or after `T0`.
Set `END` to the line number of the last log line with a time at or before `T1`.
Make sure the range holds exactly one server start and one server stop.
Make sure that every request time in the range is inside the period.
If the range holds requests from other conversations, build a range for the request lines of the period.
Delete only that range.
Delete the range in place.

```bash
sed "${START},${END}d" "$L" > /tmp/lms.filtered && cat /tmp/lms.filtered > "$L" && rm /tmp/lms.filtered
```

Leave the server log of the deleting session.
Its server log still holds the ID.
You remove it when you delete this session.

## Step 4: Delete the OpenCode Log Lines

Run this step last.
The OpenCode log holds the ID lines of your delete commands.
It can also hold lines that quote conversation content.
Delete the ID lines in place.

```bash
S="ses_0123""abc"
L="$HOME/.local/share/opencode/log/opencode.log"
grep -v "$S" "$L" > /tmp/oc.filtered && cat /tmp/oc.filtered > "$L" && rm /tmp/oc.filtered
```

The command removes every line that holds the session ID.
The log grows while you run this procedure.
This shows that the in-place write works.

## Step 5: Examine the Other Locations

Examine the storage locations for the target session.

```bash
S="ses_0123""abc"
grep -rl "$S" ~/.local/share/opencode/storage ~/.local/share/opencode/snapshot ~/.local/share/opencode/tool-output 2>/dev/null
```

Delete any file that holds the session ID.
Examine `~/.Trash`. Delete any file of the target session.

```bash
ls -la ~/.Trash
```

Examine `/tmp`. Delete any output file that remains.

```bash
ls /tmp/*.filtered 2>/dev/null
```

The shell of this procedure does not write history.
Examine the history file only if a person entered a command in a terminal.

```bash
grep -c "$S" ~/.zsh_history 2>/dev/null
```

Delete any history line that holds the session ID.
Examine the system log of macOS for the model process.

```bash
log show --last 24h --predicate 'process CONTAINS[c] "lmstudio" OR process CONTAINS[c] "llama"' 2>/dev/null | wc -l
```

The result must be very small.
Examine `~/.lmstudio/conversations/`. Delete a file only if its time is inside the period and a person used the LM Studio UI.
Examine the LM Studio main log for request content. The result must be zero.

```bash
grep -c "chat/completions" ~/Library/Logs/LM\ Studio/main.log
```

Examine `~/.lmstudio/.internal/model-data.json`. The file holds model data and times only. Leave it.
Examine `~/Library/Application Support/LM Studio/`. The files hold UI settings only. Leave them.
After a server stops, its memory holds no content. Nothing remains on storage.

## Step 6: Verify

Build the session ID from fragments.
Never enter conversation content in a command.
The database must hold zero entries of the target.

```bash
S="ses_0123""abc"
sqlite3 ~/.local/share/opencode/opencode.db "SELECT
 (SELECT count(*) FROM session WHERE id='$S'),
 (SELECT count(*) FROM message WHERE session_id='$S'),
 (SELECT count(*) FROM part WHERE session_id='$S'),
 (SELECT count(*) FROM event WHERE aggregate_id='$S');"
```

The search must find only the OpenCode database.

```bash
grep -r -a -l "$S" ~/.local/share/opencode
```

Make sure that the ID rows of the database are rows of the deleting session.

```bash
sqlite3 ~/.local/share/opencode/opencode.db \
 "SELECT session_id FROM part WHERE data LIKE '%$S%' GROUP BY session_id;"
```

The OpenCode log must hold zero ID lines.

```bash
grep -c "$S" ~/.local/share/opencode/log/opencode.log
```

The server log must hold zero lines in the period.

```bash
grep -c "$S" "$L"
```

Make sure the first request time after the period is after `T1`.
The file still grows if the server is live.
This shows that the in-place write works.

## Step 7: Delete the Deleting Session

After this procedure, the deleting session holds the ID of the target.
Its server log also holds the ID.
Leave the deleting session. Start a new session.
Run this runbook with the deleting session as the target.
Stop after you delete the deleting session.
Do not run this runbook a third time.
If you delete a third time, you remove only the second session.

## Step 8: Make Your System Safer (Optional)

Open the LM Studio settings file.
Change the value of `logSensitiveData` to `false`.
Save the file.
New conversations then do not reach the server log.
Time Machine keeps saved copies of files in local snapshots.

```bash
tmutil listlocalsnapshots /
```

Delete old snapshots when you want to remove all content.
Copies of these locations on other networks also keep old content.
If the conversation used a model on a network, the content also lives on the system outside the Mac.
This runbook cannot remove that content.
