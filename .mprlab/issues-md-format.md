# ISSUES.md Format

This document defines the canonical ISSUES.md syntax and identifier scheme.

## Structure

- Start the file with a title line, for example `# ISSUES`.
- Group issues under level-2 headings.
- Use only `BugFixes`, `Improvements`, `Maintenance`, `Features`, and `Planning` as section names.
- Use optional subheadings only to organize a section.
- Keep each issue ID in the section that matches its first letter.
- Do not put numeric ranges in section headings.
- Treat entries under a `Recurring` subheading as recurring entries.

## Issue Entries

Each issue entry is one list item:

```text
- [ ] [B042] (P1) {I007} Short title
```

- Use `[ ]` for an open issue.
- Use `[-]` for a taken issue.
- Use `[!]` for a blocked issue.
- Use `[x]` for a closed issue.
- Give each issue an external ID and a title.
- Put optional priority and dependency values immediately after the ID.
- For each blocked issue, include one indented `Blocked:` line in its body.

## Identifiers

Use `<SectionLetter><SequenceNumber>[R]`.

- Use `B` for BugFixes.
- Use `I` for Improvements.
- Use `M` for Maintenance.
- Use `F` for Features.
- Use `P` for Planning.
- Use three digits for each sequence number.
- After sequence number `999`, continue the identifier search at `001`.
- Select an identifier absent from both the active tracker and its archive.
- If all identifiers in the section are occupied, stop and request an identifier decision.
- Use a capital `R` suffix for a recurring issue, for example `[M001R]`.
- Do not use a separate `R` token.
- Accept a lowercase `r` suffix during parsing.
- Render the recurring suffix as a capital `R`.
- Do not use a repository prefix in an ID.
- Reject legacy repository-prefixed IDs, for example `IM-###`.

A recurring issue defines standing or repeated work. Scheduling data and job IDs are outside this syntax.

## Issue References

- Always reference each issue by its ID, for example `B001` or `I027`.
- Never use an `ISSUES.md` file path, line number, or `path:line` syntax as an issue reference.

## Priority and Dependencies

- Use `(P0)` through `(P2)` for an optional priority.
- Use `{ID,ID}` for optional comma-separated dependencies.

## Body Text

- Separate an inline body from the title with a space, an em dash, and a space.
- Indent each additional body line by two spaces.
- Indent each fenced code block by two spaces.
- Use plain labels for a structured issue body.
- Use `Goal:`, `Requirements:`, `Deliverables:`, `Validation:`, and `Blocked:` as the canonical labels.
- Use `Blocked:` only for a blocked issue.
- In `Blocked:`, identify the dependency, input, or policy decision that prevents progress.
