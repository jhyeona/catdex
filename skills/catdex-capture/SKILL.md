---
name: catdex-capture
description: Save a requested development note and optional task candidates to the local Catdex planner, with project and conversation context. Use when the user asks to record something in Catdex; do not capture ordinary conversation automatically.
---

Save the user's original note and useful context with `catdex capture --json`.
The planner displays candidates for user confirmation; this skill does not confirm tasks, schedule work, or run the recorded work.

1. Preserve the original text. Include the current project directory, and `CODEX_THREAD_ID` when available. Select a short, relevant conversation excerpt or clearly labeled summary; do not copy unrelated conversation or credentials.
2. Derive zero or more actionable candidates. Informational notes have `candidates: []`. Keep desired working date/time separate from deadline. Resolve relative dates against the user's local current date and timezone. Leave uncertain values absent and describe uncertainty in `note`.
3. Generate one UUID `requestID` for this capture and reuse it for retries. Write JSON using a structured serializer to a temporary file, then pass it to the command's standard input. Never interpolate the note into executable shell syntax.
4. Report success only after the CLI returns `ok: true`. Mention the candidate count and that the user can confirm candidates in Catdex's 기록함. If the command fails, retain the same request ID and report the failure; do not claim the record was saved.

Input shape (dates are ISO 8601 with timezone, omitted values remain unspecified):

```json
{
  "requestID": "a-new-uuid",
  "text": "로그인 토큰 만료 버그 내일 오전에 확인. 40분 예상",
  "project": "/absolute/project/path",
  "sessionID": "optional-thread-id",
  "context": "Relevant excerpt or labeled summary of reproduction steps",
  "candidates": [
    {
      "title": "로그인 토큰 만료 버그 확인",
      "estimatedMinutes": 40,
      "preferredStartHour": 9,
      "preferredEndHour": 12,
      "note": ""
    }
  ]
}
```

Optional candidate fields: `plannedDay` (desired working date), `dueAt` (deadline), `preferredStartHour` / `preferredEndHour` (24-hour clock; end up to 24), `estimatedMinutes` (1–1440), and `note`. Use `plannedDay` for “내일 오전에 확인”, not `dueAt`. One record may have multiple candidates with distinct titles. Candidate IDs are generated when omitted.

`project` and `sessionID` default to the CLI working directory and `CODEX_THREAD_ID` when omitted. `candidates` omitted invokes the conservative offline parser; an explicit empty array preserves a memo without inferred tasks. Output: `{"ok":true,"recordID":"...","candidateCount":1}`; failure exits nonzero with `{"ok":false,"error":"..."}`.

Invoke this skill through `/skills` → `catdex-capture`, or name the skill in the conversation. `/기록` is supported in Catdex's own quick-entry window; do not promise it as a built-in Codex slash command.
