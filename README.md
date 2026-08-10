# obsidian-tasks

Group and manage [Obsidian](https://obsidian.md) tasks from the terminal, built on
the [Obsidian CLI](https://obsidian.md/cli).

Tasks live in the notes where they were written — meetings, projects, daily notes.
That placement is a feature: a task means more next to the discussion that produced
it. This tool gathers them into one view without moving them.

## Requirements

- Obsidian, running, with the CLI enabled
- `jq`
- `coreutils` (for `timeout` — macOS ships no `/usr/bin/timeout`; `brew install coreutils`
  provides it as `timeout` or `gtimeout`, either is detected automatically)
- `fzf` (optional — `pick` falls back to a numbered prompt)

Runs on bash 3.2 (the macOS system bash) and later.

## Usage

```bash
obsidian-tasks by-date              # open tasks, grouped by when their note changed
obsidian-tasks by-date --created    # group by note creation date instead
obsidian-tasks by-date --since 7d   # only notes touched in the last week
obsidian-tasks by-date --all        # include completed tasks

obsidian-tasks by-file              # group by source file

obsidian-tasks pick                 # fuzzy-select tasks and toggle them
obsidian-tasks pick --since 7d      # ...narrowed to this week
obsidian-tasks toggle "Notes/Standup.md:7"
obsidian-tasks toggle "Notes/Standup.md:7" --done
```

Date buckets are Today, Yesterday, This week (2–7 days), Last week (8–14 days),
and Older, measured from local midnight. Boundaries are inclusive at 1, 7, and 14
days, so a note touched exactly a week ago lands in "This week". Empty buckets are
omitted.

In `pick`, TAB selects multiple tasks and ENTER toggles them all.

## How it works

`obsidian tasks format=json` returns each task's `file` and `line`. Joined with a
colon, those form the `ref=<path:line>` that `obsidian task` accepts — so reading
and writing share one identifier, and no local index or state file exists.

Grouping by date needs one `obsidian file` call per distinct file to read
timestamps. In practice a full run takes well under a second.

## Safety

`pick` re-fetches immediately before toggling and compares each selected task's
text against what you saw. If a line moved or the task vanished — because the note
was edited while the picker was open — it is skipped with a message rather than
toggled blindly. Line numbers are positional, so this matters more than it sounds.

If one toggle fails mid-batch, the rest are abandoned: a failure usually means the
refs are stale or the wrong vault is focused, in which case continuing would write
to the wrong places.

Set `OBSIDIAN_TASKS_DRY_RUN=1` to print what would be written without writing it.
The guard sits in the CLI wrapper itself, not just the write helper, so no code
path can bypass it.

Reconciliation matches on file, line, and task text — it has no stable task ID to
key on, since the CLI exposes none. If your task moves and a different task with
identical wording ends up at the old file:line ref, `pick` cannot tell them apart
and may toggle the wrong one. In practice this requires exact duplicate text in
the same file, which is rare, but it is a real limitation of text-based
reconciliation rather than a guarantee this tool makes.

## Known limitations

- **Active vault only.** The CLI's `vault=` option is documented but has no effect;
  every command targets whichever vault Obsidian currently has focused. If you
  switch vaults mid-run, refs resolved against the old one will fail — the tool
  reports that rather than writing to the wrong place.
- **Obsidian must be running.** The CLI hangs rather than failing otherwise; calls
  time out after 25s (`OBSIDIAN_TIMEOUT` to change).
- **File dates, not task dates.** The CLI exposes no per-task timestamp, so
  grouping uses the source *file's* created/modified time. A note touched for an
  unrelated reason drags its tasks along with it.
- **Metadata failures degrade, they don't crash.** If a file's timestamps can't be
  read, its tasks appear under "Older" with a warning on stderr rather than taking
  the whole listing down. `--since` never hides these tasks either — a task whose
  date is unknown always passes the filter, since hiding it would look like data
  loss.

## Environment

| Variable | Effect |
|---|---|
| `OBSIDIAN_TASKS_DRY_RUN=1` | Print write commands instead of executing them |
| `OBSIDIAN_TIMEOUT` | CLI timeout in seconds (default 25) |
| `OBSIDIAN_BIN` | Path to the `obsidian` binary (default `obsidian`) |

## Tests

```bash
bash tests/run.sh
```

77 tests, running entirely against fixtures and stubs — they never touch a vault or
invoke the real `obsidian` binary. Worth running under both bash versions, since
the two disagree on syntax the code deliberately avoids:

```bash
/bin/bash tests/run.sh              # macOS system bash 3.2
/opt/homebrew/bin/bash tests/run.sh # modern bash
```

## Layout

| File | Responsibility |
|---|---|
| `bin/obsidian-tasks` | Argument parsing and command dispatch |
| `lib/obsidian.sh` | Every CLI invocation: timeout, dry-run guard, error detection |
| `lib/fetch.sh` | Task JSON + per-file metadata → one enriched structure |
| `lib/render.sh` | Date bucketing, grouping, formatting, the fzf picker |
