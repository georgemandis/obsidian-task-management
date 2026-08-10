# Roadmap

What's built, what's deliberately deferred, and what to consider next. Written at
the end of the first build (2026-08-10), before any real daily use.

## Where this stands

v1 does what it set out to do: group vault tasks by date or file, and toggle them
from the terminal. It's merged, installed, and verified against a real vault.

The next input should be **a week of actually using it**. Several questions below
can only be answered that way, and guessing at them now would be building on
speculation. Nothing here is committed work.

## Open questions only real use can answer

**Is `modified` the right proxy for task recency?**
Tasks inherit their *file's* timestamp, because the CLI exposes no per-task date.
A note touched for an unrelated reason drags all its tasks to the top. That may be
useful signal (you were just in there) or pure noise. Watch for tasks that surface
prominently for no reason you recognize.

**Do all five date buckets earn their place?**
Today / Yesterday / This week / Last week / Older. An early reading suggested the
scheme was too fine-grained, but that turned out to be a bug — file metadata was
mostly unread, collapsing everything into "Older". With that fixed, four of five
buckets populate. Revisit only if "Last week" stays persistently empty. The natural
collapse, if it comes to that, is Today / This week / Older.

**Does `pick` exiting after a toggle become annoying?**
It exits by design: fzf ends on ENTER, and re-entering costs another fetch. If you
find yourself running `pick` repeatedly in a row, that's the signal a persistent
view is worth building — and the strongest argument for the TUI below. If you don't,
fzf was enough and a TUI would be ceremony.

**Is `--since 7d` your default?**
The hypothesis when designing was yes. If it turns out you always type it, make it
the default and add a `--all-time` escape hatch instead.

## Candidate next steps

Roughly in order of expected value. None is scheduled.

### 1. A `pick` loop, or a Bun + Ink TUI

The original idea. Justified only if the "exits after toggle" question above says so.
The cheap version is looping `pick` until you escape — a few lines, and it may fully
satisfy the itch. The expensive version is a persistent Ink TUI with live state.
Try the cheap one first.

Note the fetch is fast (~0.45s for a 13-file vault), so a re-fetching loop is
perfectly viable. Caching is *not* needed — that question is closed.

### 2. Task creation (`add`)

Currently read-and-toggle only. An `add` command that appends to today's daily note
(`obsidian daily:append`) or a chosen file would close the loop, letting the tool be
the only thing you touch. Worth doing once you trust the read side.

### 3. Grouping by something other than date or file

Tags, folder, or project. `obsidian tags file=<name>` exists, so tag-grouping is
tractable. Whether it's *useful* depends on whether your tasks carry meaningful tags
— check before building.

### 4. Multi-vault support

Blocked upstream, not by us. The CLI's `vault=` option is documented but has no
effect; every command targets whichever vault Obsidian has focused. If a future CLI
release fixes that, `--vault` becomes a small change: thread it through `obs()`.
Until then, the workaround is to focus the vault you want.

### 5. A web interface

Mentioned early on as an eventual want. Genuinely bigger than everything above —
it needs a server process, and the CLI only works when Obsidian is running and
focused, which makes "always available" awkward. Revisit only if the terminal
version proves it's worth the expansion.

## Deferred technical items

Carried over from implementation review. All were verified non-triggering; each is
recorded so the reasoning isn't lost.

| Item | Why it's deferred |
|---|---|
| `assert_contains` treats its needle as a glob, not a literal | Test-only. No current assertion uses a needle containing `[ ] ? *`. Revisit if one is added. |
| Task-text regex edge cases verified but untested in-suite | Non-space status chars (`/`, `>`), indented tasks, brackets in body, empty body all work — but nothing pins them. Risk is a silent regression if `\[.\]` is later "simplified". ~4 lines to close. |
| `render_picker`'s empty-string test uses a fixture, not the real pipeline | `render_by_date`'s equivalent test does route through `parse_file_meta`. Both share one `ts_of`, so this only matters if they diverge. |
| Reconciliation can't distinguish duplicate task text in one file | Inherent: the CLI exposes no stable task ID. If a task moves and an identically-worded one takes its old ref, the wrong one toggles. Documented in the README's Safety section. |
| Spec prose says "This week = 2–7 days" while boundaries are inclusive at 1/7/14 | The code and README are correct and consistent; the spec sentence is the stale artifact. |

## Lessons worth keeping

Two bugs escaped a full test suite and several rounds of review, both found only in
the last hour of work. Both share a shape: **the failure lived in a seam that
nothing exercised.**

- **`obs()` inherited stdin**, so the CLI child drained the pipe feeding the
  per-file metadata loop. It ran once — 1 of 13 files got timestamps, and `by-date`
  produced confidently wrong groupings. Invisible to every test, because each
  fixture used a single file. *A one-item fixture cannot catch a bug that starts on
  the second iteration.*
- **Symlink installation broke library resolution.** The tool resolved `lib/` relative
  to its own path, which through a symlink is the symlink's directory. Direct
  invocation always worked — the documented install method was the one path never
  tried. *Test the way users actually invoke it, not the way you invoke it.*

Also worth remembering: a regression test written against a hand-authored fixture
can pass while the real pipeline still breaks. When a bug involves data crossing a
boundary, build the test fixture *by running the real producer*.

And: `readlink -f` and `${var,,}` are GNU/bash-4 only. This project targets stock
macOS (bash 3.2, no `/usr/bin/timeout`), so verify under `/bin/bash`, not just
whichever bash is first on PATH.
