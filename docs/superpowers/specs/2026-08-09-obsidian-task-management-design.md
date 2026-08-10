# Obsidian Global Task Management — Design

**Date:** 2026-08-09
**Status:** Approved for planning

## Problem

Obsidian tasks live scattered across the notes where they were written — meetings,
projects, plans, daily notes. That placement is a feature: a task means more next to
the discussion that produced it. But it makes "what do I actually owe anyone?" a
question with no single answer.

`obsidian tasks verbose` already groups tasks by file. What's missing is grouping by
*time* — surfacing work by when its source note was last touched — and any way to act
on a task without opening the note it lives in.

## Scope

A collection of shell scripts wrapping the `obsidian` CLI. Read tasks vault-wide,
group them by date or file, and toggle them from the terminal.

Explicitly out of scope for this phase: config files, caching, task creation,
cross-vault support, and any TUI. Each is plausible later; none is needed to learn
whether date-grouping is a useful way to see this data.

## CLI findings

Established by probing the CLI directly. These constrain the design.

### The `ref` contract

`obsidian tasks format=json` returns records shaped:

```json
{
  "status": " ",
  "text": "- [ ] Follow-up norm: funnel changes must update the spec test",
  "file": "Audit/09 Week-One Action List.md",
  "line": "20"
}
```

`obsidian task` accepts `ref=<path:line>` and takes `toggle`, `done`, `todo`, or
`status="<char>"`.

**`file` + ":" + `line` is exactly the `ref` format.** Read and write share one
identifier. This is the foundation of the whole design: every task carries its own
handle, so there is no index to maintain, no state file, and nothing that can drift
out of sync.

### Costs and shapes

- **Volume:** Starlight has 184 tasks. (Notes had 193 across 32 files.) Small enough
  that every operation can be naive — no pagination, no incremental fetch.
- **`todo` filter is server-side.** `obsidian tasks todo` filters before output. In
  Notes, 122 of 193 were open — roughly a third fewer records to parse.
- **File metadata:** `obsidian file path=<p>` returns TSV (not JSON — `format=json`
  is ignored) with `created` and `modified` as **epoch milliseconds**.
- **Metadata cost:** ~0.18s per call, one per distinct file. Expect ~30 calls, ~6s
  for a date-grouped run.
- **`text` includes the `- [ ] ` prefix**, which must be stripped for display.

### Limitations

1. **`vault=` does not work.** Documented on every command, but has no effect:
   `obsidian vault info=path vault=Notes` returns Starlight's path, and
   `obsidian tasks total vault=Notes` returns Starlight's count. All commands target
   whatever vault Obsidian currently has focused.

   *Consequence:* the active vault is ambient state that can change mid-run. This was
   hit live during design — paths resolved against Notes began failing when focus
   moved to Starlight. Mitigated by the user keeping only Starlight open; the
   exit-status check below remains as insurance.

2. **The CLI hangs when it can't complete**, rather than failing. `obsidian --version`
   sat until killed. Every invocation needs a timeout wrapper.

3. **Line numbers are positional.** Any edit above a task shifts its ref. Refs are
   valid at fetch time and not assumed valid afterward.

4. **fzf hides ref from matching *and* from search.** Verified: with
   `--with-nth=1..-2`, searching a substring of the hidden column returns nothing.
   So the source filename must be a *visible* column for filename search to work.

## Architecture

```
bin/obsidian-tasks     # dispatcher: by-date | by-file | pick | toggle
lib/fetch.sh           # tasks JSON + file metadata -> enriched JSON
lib/render.sh          # grouping + formatting
```

One fetch, one enrichment, many renderers:

```
obsidian tasks todo format=json ──┐
                                  ├─→ enriched ─→ by-date | by-file | pick
obsidian file path=<f>  × ~30 ────┘   (ref, text, status, file, created, modified)
```

Enrichment steps:

1. Fetch task JSON (with `todo` unless `--all`).
2. `jq`: add `ref` = `file + ":" + line`; strip the `- [ ] ` / `- [x] ` prefix from `text`.
3. For each distinct `file`, fetch metadata; parse TSV with `awk`.
4. `jq`: join metadata onto tasks by file path.

`pick` and `toggle` consume this same structure rather than re-deriving anything.

## Commands

```
obsidian-tasks by-date [--created] [--all] [--since <n>d]
obsidian-tasks by-file [--all]
obsidian-tasks pick    [--all] [--created]
obsidian-tasks toggle <ref> [--done|--todo]
```

### by-date

The reason this project exists. Buckets tasks by their source file's `modified`
timestamp — or `created` with `--created`. Within each bucket, tasks group under
their source file.

Buckets use **rolling windows from now**, not calendar boundaries — so the output
doesn't reshuffle depending on which weekday you run it:

| Bucket | Window |
|---|---|
| Today | since local midnight |
| Yesterday | the prior midnight-to-midnight day |
| This week | 2–7 days ago |
| Last week | 8–14 days ago |
| Older | more than 14 days ago |

Empty buckets are omitted.

```
## Today
  Audit/09 Week-One Action List.md
    [ ] Follow-up norm: funnel changes must update the spec test
    [ ] Chase the invoice

## Yesterday
  Meetings/Standup.md
    [ ] Ask about staging deploy
```

`--since 7d` filters to files touched within a window. This is the flag that turns
184 tasks into a short list, and is expected to become the daily default.

### by-file

Thin wrapper over `obsidian tasks verbose`, normalized to match `by-date`'s output so
the two read alike. Nearly free to implement.

### pick

fzf multi-select over the flattened list. Tab to select several, enter to toggle them
all, and the script prints what changed.

Each line renders visible columns — status, text, date bucket, source file — plus a
hidden trailing ref column. fzf displays and matches only the visible part
(`--with-nth=1..-2`); the ref is stripped off the selected line and passed to
`obsidian task`. No state is stored between runs; the ref travels inside the line.

```bash
lines=$(printf '%s\n' "$rendered" | fzf --ansi --multi --with-nth=1..-2 --delimiter='\t')
while IFS= read -r line; do
  ref=${line##*$'\t'}
  obsidian task ref="$ref" toggle
done <<< "$lines"
```

Exits after toggling rather than looping — looping would cost another ~6s metadata
fetch per round. Whether that's worth caching is a question for after real use.

Falls back to a numbered prompt when fzf is absent, so `pick` works on any machine.

### toggle

Takes a raw `ref` and flips it; `--done` / `--todo` set explicitly instead of
toggling. This is the scriptable primitive `pick` calls internally, and what makes
the tool composable from other scripts.

## Error handling

Three failure modes, all observed or derived during design:

1. **Vault switched mid-run.** A ref valid in one vault silently fails in another.
   Every write checks exit status and stderr for `not found`, and halts with a clear
   message rather than continuing down a list of selections.

2. **Obsidian not running.** The CLI hangs instead of failing. Every invocation is
   wrapped in a timeout; a hang is reported as "Is Obsidian running?"

3. **Stale line numbers.** `pick` re-fetches immediately before toggling, narrowing
   the staleness window to seconds.

**Dry-run:** `toggle` and `pick` respect `OBSIDIAN_TASKS_DRY_RUN=1`, printing the
`obsidian task ref=...` command instead of executing it.

## Testing

**Unit-tested** (JSON/TSV fixtures in, text out, no CLI): date bucketing, ref
construction, TSV metadata parsing, checkbox-prefix stripping, `--since` window
filtering, ref extraction from an fzf line.

**Smoke test** at the CLI boundary: create a scratch note, toggle a task in it,
verify, delete it. Run deliberately, never automatically, and only with explicit
consent — the test suite must never toggle real tasks in a live vault.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Date source | Both, `--modified` default | Same fetch, different field — nearly free |
| Default filter | Todo only, `--all` opts in | ~1/3 fewer records; filtered server-side |
| Phase 1 scope | by-date + toggle + fzf picker | Proves read→identify→write; may make Ink unnecessary |
| Multi-select | Included | Cheap; partly covers fzf exiting on enter |
| Vault targeting | Active vault only | `vault=` is non-functional; user runs one vault |

## Open questions for later phases

- Does ~6s metadata fetch grate enough to justify a cache?
- Does `pick` exiting after toggle become annoying enough to want a loop — and is
  that the point where Ink earns its place?
- Is file `modified` the right proxy for task recency, or does it mislead when a
  note is touched for unrelated reasons?
