# Technical Documentation

Use ASD-STE100 Simplified Technical English, Issue 9, January 2025, for new or changed English technical prose.
This contract applies to PRDs, architecture documents, trackers, plans, policies, ADRs, READMEs, runbooks, API documents, and agent guides.

Preserve facts, requirements, interfaces, and ownership boundaries.
Record an unspecified product decision in `Open Decisions`.
Keep assumptions separate from confirmed requirements and acceptance criteria.
Preserve code, commands, paths, identifiers, URLs, quotations, proper names, legal text, and third-party text as source-controlled literals.

## Official Reference Gate

Before prose edits, run the Governor `prepare-ste-reference --json` command.
It retrieves the official [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf) PDF and verifies its pinned SHA-256.
The cache stays outside the target repository.

Use Part 1 for writing rules and Part 2 for the controlled dictionary.
If retrieval or verification fails, stop prose edits and report the source blocker.
Read-only analysis can continue.
Use only the verified official reference.
Keep the PDF and its dictionary outside generated files, commits, and redistributed artifacts.

The producing agent owns the rule and dictionary review.
Do not assign retrieval, review, or compliance decisions to the end user.

## Terminology

- Read the target `.mprlab/TERMINOLOGY.md` before you write prose.
- Use dictionary words only with their approved meaning and part of speech.
- Use technical nouns and technical verbs with one defined meaning.
- Add necessary repository terms before their first use in prose.
- Keep general dictionary words out of the technical glossary.
- Use the same term for the same concept.
- Preserve the exact spelling of names and source-controlled literals.

## Writing Rules

| Text type | Rules |
| --- | --- |
| Procedure, requirement, or acceptance criterion | Use the imperative. Give one instruction per sentence. Use at most 20 words per sentence. |
| Description, context, or status | Give one idea per sentence. Use at most 25 words per sentence. |
| Paragraph | Give one topic. Use at most six sentences. |
| Conditional instruction | Give the condition first, then the action. |
| Note | Give information only. Put instructions in the procedure. |

- Use American English spelling.
- Use the active voice. Descriptive text can use the passive voice when the agent is unknown.
- Use simple present, simple past, simple future, imperative, or infinitive verb forms.
- Use an `-ing` form only in an approved word or technical noun.
- Use direct verbs and approved phrasal verbs.
- Keep a multi-word noun to three words or fewer.
- Use necessary articles.
- Use `must` for requirements and `can` for capability.
- Separate preferred methods from binding requirements.
- Use vertical lists for related requirements and procedures.
- Write instructions in execution order.
- Keep contractions, semicolons, unapproved synonyms, and ambiguous pronouns out of new prose.

Use descriptive writing for product and architecture context, ADR decisions, issue goals, and status.
Use procedural writing for requirements, issue deliverables, validation steps, and runbooks.
Use the simple past tense for changelog entries.

## Instructions For Agents

- State the condition, action, and expected result of each operational step.
- Name the command, input, output, and failure action when they control execution.
- Assign each shared rule one authoritative location.
- Reference the rule owner from dependent guides.
- Give explicit reading conditions for task-specific references.
- Separate required context from optional background.
- Keep examples only when they resolve a concrete ambiguity.
- Distinguish a tool result from the broader outcome it can prove.

## Review Gate

1. Identify the changed prose and classify each section as procedural or descriptive.
2. Verify the facts and preserve the source meaning.
3. Apply the terminology and writing rules.
4. Run `check-ste` on each changed document.
5. Correct mechanical findings in the changed text.
6. Review all changed prose against applicable Part 1 rules.
7. Review each general word against Part 2 for its meaning and part of speech.
8. Report the reviewed scope and remaining findings.

The checker finds selected mechanical errors only.
It does not certify dictionary usage, factual accuracy, or complete ASD-STE100 compliance.
Claim full-document compliance only after you review the complete document against both parts.
For a partial revision, distinguish reviewed changes from unchanged text.
