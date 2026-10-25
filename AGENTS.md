# AGENTS.md

DropWheel is two repos kept in feature parity:

- **This repo** (macOS, Swift/AppKit) — the source of truth; new features land here first.
- **DropWheel-Windows** (`../DropWheel-Windows` locally, `github.com/Umairius/DropWheel-Windows`)
  — the C#/.NET 8 WPF port.

## Porting to Windows

When the user asks to port/sync recent work to Windows ("port to windows", "sync the
windows port", "push the port", after finishing a feature):

1. Read and follow `.agents/skills/port-to-windows/SKILL.md`.
2. Use `PORT_MAP.md` (same directory) for the macOS→Windows file mapping, known feature
   gaps, and framework translation.

## Ground rules for any agent in this repo

- Port **behavior**, not code — the two stacks share no frameworks.
- Never modify macOS sources while porting; port work happens in the Windows repo.
- `DropWheel.Core` and `tests/SmokeTest` (Windows repo) build on any OS with the .NET 8
  SDK; `DropWheel.App` (WPF) only builds on Windows.
- ffmpeg/pandoc are GPL: they are invoked as external processes only, never linked.
