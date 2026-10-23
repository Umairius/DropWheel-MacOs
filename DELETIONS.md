# Every place DropWheel can remove, trash or replace a file

Generated from the source (`Tools/audit-deletions.sh` re-checks it). 30 call sites. Categories:

- **TRASH**: goes to the macOS Trash, recoverable. Never a hard delete.
- **OWN-PARTIAL / OWN-TEMP / OWN-STAGING**: a file or folder DropWheel itself created seconds earlier (half-written output, temp file, extraction staging). Output paths are chosen by `uniqueOutput`, which only returns a path that does not exist yet, so these can never be a file of yours.
- **APP-DATA**: DropWheel's own files inside Application Support. Not user files.

**No call site ever touches an original you dragged in, except "Replace" mode (off by default), which moves it to the Trash after the new file exists and is not empty.**

Also checked: nothing runs `rm`, `mv`, `find -delete`, or `recycle`. ffmpeg now runs with `-n` (never overwrite) instead of `-y`. `zip` only ever writes to the fresh output path. LibreOffice and unpack results are moved with `moveItem`, which refuses to overwrite.

| File | Line | Category | What it is |
|---|---|---|---|
| ArchiveBackend.swift | 82 | OWN-STAGING | Hidden ".dropwheel-UUID" staging folder DropWheel created for the extraction. Emptied by moving results out first. |
| ArchiveBackend.swift | 107 | OWN-STAGING | Junk entries dropped from the freshly extracted copy in staging. The archive itself is never touched. |
| ArchiveBackend.swift | 109 | OWN-STAGING | Junk entries dropped from the freshly extracted copy in staging. The archive itself is never touched. |
| Backends.swift | 200 | OWN-TEMP | Temp file/folder in the system temp folder (LibreOffice / Markdown conversion). |
| Backends.swift | 253 | OWN-TEMP | Temp file/folder in the system temp folder (LibreOffice / Markdown conversion). |
| Backends.swift | 359 | OWN-TEMP | Temp file/folder in the system temp folder (LibreOffice / Markdown conversion). |
| Converter.swift | 113 | OWN-TEMP | Temp file in the system temp folder that this conversion created. |
| Converter.swift | 219 | OWN-TEMP | Temp file in the system temp folder that this conversion created. |
| Converter.swift | 225 | OWN-TEMP | Temp file in the system temp folder that this conversion created. |
| Converter.swift | 369 | OWN-PARTIAL | The half-written output of a conversion that just failed. Its path was verified free (uniqueOutput) before writing, so it cannot be one of your files. |
| Converter.swift | 390 | TRASH | "Replace" mode only (off by default): the original goes to the Trash after a successful, non-empty result. Never deletes. |
| Converter.swift | 395 | OWN-PARTIAL | The half-written output of a conversion that just failed. Its path was verified free (uniqueOutput) before writing, so it cannot be one of your files. |
| MediaBackend.swift | 31 | OWN-PARTIAL | Half-written video/audio output removed before retrying with a different encode. Path was verified free first. |
| MediaBackend.swift | 74 | OWN-PARTIAL | Half-written video/audio output removed before retrying with a different encode. Path was verified free first. |
| MediaBackend.swift | 79 | OWN-PARTIAL | Half-written video/audio output removed before retrying with a different encode. Path was verified free first. |
| MediaBackend.swift | 83 | OWN-PARTIAL | Half-written video/audio output removed before retrying with a different encode. Path was verified free first. |
| MediaBackend.swift | 111 | OWN-TEMP | Temp folder for the SVG render. |
| PDFBackend.swift | 85 | OWN-PARTIAL | The compressed PDF it just wrote, discarded because it was not smaller. The original is untouched. |
| ResultToast.swift | 48 | TRASH | Undo, only on an explicit click: moves the files THIS conversion just made to the Trash, and only if they are unchanged since. Never deletes. |
| SignBackend.swift | 26 | OWN-TEMP | Temp PDF made from a document/image just for signing. |
| SignBackend.swift | 89 | OWN-PARTIAL | The signed copy it was writing, discarded because it failed its own self-check. Path was verified free first. |
| SignBackend.swift | 92 | OWN-PARTIAL | The signed copy it was writing, discarded because it failed its own self-check. Path was verified free first. |
| SignBackend.swift | 99 | OWN-PARTIAL | The signed copy it was writing, discarded because it failed its own self-check. Path was verified free first. |
| SignBackend.swift | 128 | OWN-TEMP | Temp stamp overlay PDF. |
| SignWindow.swift | 959 | TRASH | You pressed "Move it to the Trash" on a signed copy that failed its self-check. Recoverable. |
| SignatureStore.swift | 102 | APP-DATA | DropWheel's own plaintext signature file, removed only AFTER the encrypted copy was written successfully. |
| ToolInstaller.swift | 198 | APP-DATA | Helper-tool downloads and staging inside Application Support/DropWheel (ffmpeg, pandoc). Not your files. |
| ToolInstaller.swift | 229 | APP-DATA | Helper-tool downloads and staging inside Application Support/DropWheel (ffmpeg, pandoc). Not your files. |
| ToolInstaller.swift | 334 | APP-DATA | Helper-tool downloads and staging inside Application Support/DropWheel (ffmpeg, pandoc). Not your files. |
| ToolInstaller.swift | 335 | APP-DATA | Helper-tool downloads and staging inside Application Support/DropWheel (ffmpeg, pandoc). Not your files. |
