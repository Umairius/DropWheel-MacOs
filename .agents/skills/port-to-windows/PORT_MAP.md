# PORT_MAP — macOS file → Windows counterpart

Read this when classifying changes (step 3 of SKILL.md).
`mac` = this repo (`Sources/DropWheel/*.swift`), `win` = DropWheel-Windows repo.

## Core plumbing

| macOS | Windows counterpart | Notes |
|---|---|---|
| `main.swift` | `src/DropWheel.App/Program.cs`, `src/DropWheel.App/Cli.cs` | entry point + headless CLI flags |
| `App.swift` | `src/DropWheel.App/AppController.cs`, `TrayController.cs`, `Settings.cs` | wiring, tray menu, settings persistence |
| `DragWatcher.swift` | `src/DropWheel.App/DragWatcher.cs` | 30 Hz polling: button + trigger key + movement |
| `WheelPanel.swift` | `src/DropWheel.App/OverlayWindow.cs`, `WheelControl.cs` | non-activating overlay, pie segments, geometric hit-test |
| `Converter.swift` | `src/DropWheel.Core/Converter.cs`, `Registry.cs`, `Model.cs` | recipes, unique output names, replace mode |
| `Backends.swift` | `src/DropWheel.Core/Backends.cs`, `Tools.cs`, `Shell.cs` | engine discovery + external tool execution |
| `ImageBackend.swift` | `src/DropWheel.Core/Backends.cs` (libvips engine) | ImageIO → libvips |
| `MediaBackend.swift` | `src/DropWheel.Core/Backends.cs` (ffmpeg engine) | AVFoundation/afconvert → ffmpeg |
| `PDFBackend.swift` | `src/DropWheel.Core/Backends.cs`, `PdfOps.cs`, `MiniPdf.cs`, `src/DropWheel.App/WindowsServices.cs` | PDFKit → pdfcpu / WinRT render / PdfPig text / MiniPdf write |
| `DataBackend.swift` | `src/DropWheel.Core/DataBackend.cs` | CSV↔JSON, pure on both sides |
| `ArchiveBackend.swift` | `src/DropWheel.Core/Backends.cs` | /usr/bin zip/tar → System.IO.Compression, tar.exe |
| `MiniMarkdown.swift` | `src/DropWheel.Core/MiniMarkdown.cs` | tiny md→html fallback, pure on both sides |
| `ToolInstaller.swift` | `scripts/fetch-tools.ps1` | mac downloads at runtime; windows at dev/build time |

## Docs / build

| macOS | Windows counterpart |
|---|---|
| `README.md` | `README.md` (keep "Using it" / tools table / known limits in sync) |
| `CHANGES.md` | `sync/PORT_LOG.md` + installer workflow release notes |
| `DELETIONS.md` | safety review: every delete/trash site in `Core/Fs.cs`, `Converter.cs` (only opt-in Replace trashes originals) |
| `Package.swift` | `src/*/*.csproj` |
| `build_app.sh`, `make_dmg.sh` | `scripts/run.ps1`, `installer/DropWheel.iss`, `.github/workflows/build-installer.yml` |

## Known feature gaps (the DEFER list)

- `ResultToast.swift` — Windows shows no result card; output lands silently next to the original.
- `SignBackend.swift`, `SignWindow.swift`, `SignaturePad.swift`, `SignatureStore.swift`, `SignModel.swift`, `SpotFinder.swift` — signing feature not ported at all.
- `SetupWindow.swift`, `Tutorial.swift` — first-run setup / practice tutorial not ported.
- `PDFInspector.swift` — tamper preflight not ported.
- `Sound.swift`, `Haptics.swift` — no sounds/haptics on Windows (wheel ticks are silent).

## SKIP (macOS-only, never port)

- `MainMenu.swift` — AppKit menu infra; Windows uses the tray menu in `TrayController.cs`.
- `IconKit.swift`, `IconData.swift`, `Brand.swift`, `FontData.swift` — Windows draws its own wheel icons in `WheelControl.cs`.
- `Assets/**`, `Tools/**` (node icon tooling), `build_app.sh`, `make_dmg.sh`, promo assets.

## Framework translation

| macOS | Windows |
|---|---|
| ImageIO / CoreGraphics | libvips (bundled) |
| PDFKit — render | WinRT PDF renderer via `WindowsServices.cs` |
| PDFKit — merge/split/compress | pdfcpu (bundled), `MiniPdf`/`PdfOps` fallback |
| PDF text extraction | PdfPig (the only NuGet dependency) |
| AVFoundation, afconvert | ffmpeg (bundled) |
| textutil | pandoc (bundled) / Edge headless |
| QuickLook (SVG thumbnails) | libvips SVG loader |
| `/usr/bin/zip`, `/usr/bin/tar` | System.IO.Compression, `tar.exe` |
| NSPanel + NSVisualEffectView | WPF Window with WS_EX_NOACTIVATE\|WS_EX_TOOLWINDOW, transparency |
| NSEvent polling | `GetAsyncKeyState` + DispatcherTimer (no global hooks — AV friendly) |
| CryptoKit / LocalAuthentication | (gap — signing) |
| Vision | (gap — signature spot finding) |
