---
name: Port to Windows
description: Port recently finished DropWheel features from this macOS repo to the sibling DropWheel-Windows repo (C#/.NET 8 port), verify what is verifiable on macOS, and push a branch. Use when the user asks to "port to windows", "sync the windows port", "push the port", or right after finishing a feature on the Mac side.
---

# Port to Windows

Port what was just built in this macOS repo (Swift/AppKit) into the Windows port
(C#/.NET 8, WPF + WinForms), then push. You port **behavior**, never code — the two
stacks share no frameworks.

## 0. Inputs

- Port range = commits in this repo after the last ported one, unless the user names
  specific commits or a feature.
- The last ported macOS commit SHA lives in the Windows repo at `sync/last-mac-commit.txt`.
- If the user names a feature instead of a range, find its commits with
  `git log --oneline` / `git log --grep=<words>`; if ambiguous, ask which ones.

## 1. Locate the Windows repo

1. Look for a sibling directory of this repo whose git origin URL contains
   `DropWheel-Windows` (usually `../DropWheel-Windows`). Verify with
   `git -C <dir> remote get-url origin`.
2. If not found: `git clone git@github.com:Umairius/DropWheel-Windows.git ../DropWheel-Windows`.
3. In the Windows repo: worktree must be clean (`git status --porcelain` empty — if dirty,
   stop and ask), then `git checkout main` and `git pull --ff-only`.

Never modify this (macOS) repo's sources during a port. All port work happens in the
Windows repo.

## 2. Determine what changed on the Mac side

- `BASE` = contents of `sync/last-mac-commit.txt` (or a user-supplied SHA/range).
- `HEAD` = this repo's current `HEAD`.
- If there are no commits in `BASE..HEAD`: report "already in sync" and stop.
- Collect:
  - `git log --oneline BASE..HEAD`
  - `git diff --name-status -M BASE..HEAD`
  - Per changed file: `git diff BASE..HEAD -- <file>` (use enough context to understand
    the behavior change, not just the text change).

## 3. Classify the changes

Read `PORT_MAP.md` (in this same directory) and sort every changed macOS file into:

- **PORT** — has a Windows counterpart; the behavior must be reproduced there.
- **DEFER** — maps to a known feature gap (signing, tutorial, result toast, PDF
  inspector, ...). Record it in the report and `PORT_LOG.md`. Do not build an entire new
  subsystem unless the user asked for it in this run.
- **SKIP** — macOS-only internals (haptics, NSPanel specifics, mac build scripts,
  assets, icon tooling).

Present a short plan (commits + PORT/DEFER/SKIP lists) and get a go-ahead before
implementing, unless the user already said "just do it" / "push it".

## 4. Implement (in the Windows repo)

- Read each Windows counterpart file fully before editing it (mapping in `PORT_MAP.md`).
- Reproduce user-visible behavior: conversion targets/recipes, CLI flags, wheel/UX
  semantics, tray options, naming/replace/undo behavior — in C#/.NET 8 idioms matching
  the style of neighboring code.
- No new NuGet dependencies without asking. ffmpeg/pandoc are GPL: they stay **external
  processes** invoked via `Core/Shell.cs`, never linked.
- Keep `Core/Registry.cs` target ids/labels consistent with the macOS Registry's
  user-facing set, and keep CLI parity: `--diagnose`, `--options <file>`,
  `--convert <file> <fmt>`.
- Update the Windows `README.md` when user-visible behavior, bundled tools, or known
  limits change.
- Minimal diffs: no reformatting, no drive-by refactors.
- WPF/UI code (`OverlayWindow`, `WheelControl`, `TrayController`) cannot be compiled on
  macOS — keep those changes conservative and pattern-matched to existing code, and flag
  them as "needs Windows build check".

## 5. Verify (on macOS)

```bash
cd <windows repo>
dotnet build src/DropWheel.Core -c Release
dotnet run --project tests/SmokeTest
```

- The build must succeed and the smoke test must PASS. Missing optional tools produce
  SKIPs — fine. FAIL is not fine: fix or stop and ask.
- `DropWheel.App` (WPF) cannot build here. If you touched it, state "needs Windows build
  check" in the report and PR body.

## 6. Commit + record state (in the Windows repo)

1. Stage the port changes.
2. Update `sync/last-mac-commit.txt` to the macOS SHA you ported up to.
3. Append one line to `sync/PORT_LOG.md`:
   `- <YYYY-MM-DD> <mac-short-sha> <one-line summary> (ported: ...; deferred: ...)`.
4. Make it a single commit: `Port <mac-short-sha>: <short summary>`.

## 7. Push

1. Create branch `port/<mac-short-sha>` and push it.
2. If the `gh` CLI is authenticated: open a PR to `main` (title `Port <mac-short-sha>:
   <summary>`; body = ported/deferred/skipped lists, verification results, and the
   "needs Windows build check" flag if App was touched).
3. Push straight to `main` ONLY if the user explicitly asked for that this run AND
   `DropWheel.App` was not touched AND step 5 passed.
4. Never force-push, never rewrite others' commits.

## 8. Report back

Summarize: commits ported, Windows files changed, deferred gaps, skipped macOS-only
items, verification results, branch/PR URL, and a Windows-side test checklist:
`./run.cmd` (build + launch), a drag-gesture smoke test, `DropWheel.exe --diagnose`,
and `--convert` cases covering the changed recipes.

## Guardrails

- Ask when: the range is unclear, the plan is ambiguous, a deferred gap would require a
  whole new subsystem, a new dependency is needed, or a direct `main` push is requested.
- Stop when: the Windows repo is dirty, verification fails, or the mac range contains
  unrelated WIP the user did not ask to port.
