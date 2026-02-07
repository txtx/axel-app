<div align="center">
  <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/txtx/axel-app/main/docs/assets/axel-github-dark.png">
      <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/txtx/axel-app/main/docs/assets/axel-github-light.png">
      <img alt="Surfpool is the best place to train before surfing Solana" style="max-width: 60%;">
  </picture>
</div>


Axel is for anyone who wants the **calm** of a task list and their agents in **war mode** — without losing track of what's running, where, or why.

It pairs a native macOS app with a fast [RUST CLI](https://github.com/txtx/axel) to orchestrate many AI agents across tmux panes, Ghostty based terminals, and git worktrees — with a user interface inspired by **Things**.

---

## What Axel Feels Like

- A clean, Things‑like inbox for tasks and priorities.
- A living map of your active agents, each anchored to a worktree and terminal.
- A system that literally makes “spin up another agent in a new git worktree” feel as cheap as “open a new tab.”

---

## What Axel Does

Axel turns agent work into a first‑class workflow:

- **Tasks with intent**: queue, run, and complete agent tasks with status, priority, and context.
- **Real terminals**: manage live sessions (Claude, Codex, etc.) in tmux panes and Ghostty.
- **Worktree‑first isolation**: one agent, one branch — no more stepping on each other.
- **Inbox & permissions**: see agent requests in a single stream and approve quickly.
- **Skills & context**: reusable prompts from `./skills` and `~/.config/axel/skills`.
- **Sync built‑in**: Automerge CRDT + Supabase for conflict‑free collaboration.

---

## How Axel Works (Short Version)

1. You create a task in the app.
2. Axel spawns a terminal session via the CLI.
3. The agent runs in tmux, optionally inside a new git worktree.
4. The app shows live output, events, and permission prompts.
5. When the work is done, you close the loop and ship.

---

## Components

**Native macOS app (SwiftUI)**

- Five‑column workspace layout for tasks, inbox, terminals, skills, and team.
- SSE inbox for real‑time agent events and permission requests.
- SwiftData + Automerge for local state + cross‑device sync.

**Axel CLI (Rust)**

- Launches tmux grids and agent panes.
- Reads `AXEL.md` layouts and skills.
- Manages worktrees and session recovery.

**Terminal layer**

- Ghostty for fast, modern terminal emulation.
- tmux for pane orchestration.
- git worktrees for clean agent isolation.

---

## Quick Start

Requirements: macOS 14+, Xcode 15+ (for app), Rust (for CLI dev)

```bash
# Open the app in Xcode
open Axel.xcodeproj

# Run the app (Debug)
./run.sh
```

When you launch Axel, it can install the CLI to `~/.local/bin` if it isn’t already present.

---

## A Typical Flow

```text
1. Create a task “Refactor API caching”
2. Assign it to Claude in a new worktree
3. Claude runs in tmux + Ghostty
4. Permission requests appear in Inbox
5. Review output, merge, and mark done
```

---

## Project Structure (Partial)

```
Axel/
├── Views/macOS/          # macOS UI (tasks, inbox, terminals)
├── Services/             # SSE inbox, sync, CLI orchestration
├── Models/               # SwiftData entities
Packages/
├── GhosttyKit/           # terminal emulation
├── AutomergeWrapper/     # CRDT sync wrapper
```

---

## Contributing

We want Axel to feel like a tool you *want* to use daily.

Here’s what we value in contributions:

- **Workflow‑first**: every feature should reduce mental overhead for multi‑agent work.
- **Beautifully restrained UI**: clarity and delight, never clutter.
- **Terminal authenticity**: real tmux panes, real worktrees, no fakery.
- **Performance**: fast startup, fast rendering, fast agent recovery.

If you’re interested, open an issue or send a PR with:

- a short problem statement
- a proposed solution
- any design notes or workflow details

---

## Related Experiments

We’ve built other systems in this space (not necessarily good, but useful lessons):

- https://github.com/txtx/surfpool
- https://github.com/txtx/moneymq

---

## Status

Axel is under active development. The core workflow is here, and we’re making it sharper every week.

---

See `CLAUDE.md` for workspace‑specific notes.
