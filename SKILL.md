---
name: claude-code-devlog-hooks
description: >-
  Dev-journal (devlog / 開発日誌) discipline for coding agents, enforced by
  three Claude Code hooks: SessionStart injects the routine, UserPromptSubmit
  nudges when today's log goes stale, Stop blocks turn-end once until today's
  journal is updated. Use when a session log / daily dev journal must be kept
  "little and often", when a Stop hook block message asks for today's journal
  entry, when a dev-journal nudge appears mid-session, or when setting up or
  debugging journaling hooks (enforce-once markers, fail-open, UTF-8 output).
  Keywords: dev journal, devlog, dev diary, 開発日誌, 開発ログ, session log,
  daily log, Stop hook block, journaling discipline.
---

# Dev Journal Discipline (claude-code-devlog-hooks)

A discipline for keeping a daily development journal while working as (or
with) a coding agent, plus the three Claude Code hooks that make the habit
stick. The discipline itself is tool-agnostic: any agent that can read
instructions and append to a Markdown file can follow it. The enforcement
layer (the hooks) is Claude Code specific.

## Why A Journal, And Why Hooks

Lessons learned during agent sessions — environment quirks, failed
approaches, decisions and their reasons — evaporate when the session ends.
A daily journal turns them into a searchable record, and distilled topic
notes turn repeated lessons into a first-stop reference that prevents
repeating old mistakes.

The failure mode is always the same: "I will write it up at the end." Then
the context window fills, the session ends, and nothing is written. The
three hooks exist to defeat exactly that failure mode:

| Layer | Hook event | Behavior |
| --- | --- | --- |
| Routine | SessionStart | Injects this discipline into context; records the session start time as a marker |
| Reminder | UserPromptSubmit | If the session is old enough AND today's journal is stale (default: 20 min for both), nudges once in a while — never blocks |
| Backstop | Stop | If today's journal was not touched since the session started, blocks the end of the turn once with instructions — then stays quiet |

## The Routine

1. **Before starting work**: search the `topics/` folder of the journal for
   prior lessons relevant to the task. When stuck mid-task, search it again
   before brute-forcing.
2. **During work — write little and often.** Append one item to today's
   journal (`daily/YYYY-MM-DD.md` under the devlog root) each time you:
   - learn something (a tool quirk, an environment difference, a gotcha),
   - resolve a problem (what worked, what did not),
   - decide a direction (and why),
   - reach a good stopping point.
   Do not batch it up for the end of the session. If you are told the
   journal is stale (the nudge) or blocked at turn end (the backstop), that
   is your cue that the current session has unrecorded lessons.
3. **Distill.** When you notice you are writing the same lesson a second
   time, move the general form into `topics/<kebab-slug>.md` (one theme per
   file) and link it from the daily entries with a `[[wikilink]]`. Daily
   entries are the chronological record; topics are the evergreen index.

## Entry Format

Append under a session heading (create it on first write, extend it after):

```markdown
## Session (HH:MM) [one-line summary]
- **Done**: what was done, which project, main changes
- **Learned, stuck, solved**: errors hit, what fixed them, what did not work
- **Next**: the next smallest action
- Links: [[topic-slug]] / #tag
```

Guidelines:

- Write at a granularity your future self can search: exact error strings,
  flag names, and version numbers are worth more than prose.
- Record failures and dead ends, not only successes — they are the entries
  that save the most time later.
- For a genuinely trivial session, one line is enough: `Trivial: <gist>`.
- Never write secrets, tokens, OAuth material, or real user/customer data.
  When a value seems needed, record the cause and structure instead of the
  value itself.

## Responding To The Hooks

- **SessionStart context**: treat the injected routine as standing
  instructions for the session.
- **Nudge (UserPromptSubmit)**: append one item now if anything is
  unrecorded; if truly nothing happened, ignore it — it does not block.
- **Block (Stop)**: append the entry (or the one-line trivial form), then
  end the turn normally. The block fires at most once per session thanks to
  the marker comparison; do not fight it, just write the entry.

## Journal Layout

```text
<devlog root>/            # set via CLAUDE_DEVLOG_DIR
├── daily/YYYY-MM-DD.md   # one file per day, session headings inside
├── topics/<slug>.md      # distilled evergreen notes, one theme per file
└── .devlog-markers/      # session-start markers written by the hooks
```

The layout is a convention, not a requirement of the hooks: the hooks only
read/write `daily/<today>.md` mtimes and the marker files. An Obsidian vault
folder works well as the devlog root (wikilinks resolve natively), but plain
Markdown folders work the same.

## Adopting The Discipline Without Claude Code

Other agent CLIs (for example Codex) have no hooks mechanism, so the
enforcement layer does not port. The discipline still does: paste the
routine above into the agent's standing instructions (for example
`AGENTS.md`) and state the devlog root path explicitly. You lose the
mechanical backstop; you keep the habit structure.

## Installing The Hooks

See the repository README for hook registration (three events in Claude
Code `settings.json` plus one environment variable, `CLAUDE_DEVLOG_DIR`)
and `docs/hook-engineering.md` for how and why the hooks are built the way
they are (enforce-once markers, fail-open, UTF-8 byte output).
