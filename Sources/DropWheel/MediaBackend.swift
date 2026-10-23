import AVFoundation
import Foundation

/// Audio/video via AVFoundation + afconvert (built in) and ffmpeg (optional). Also SVG via QuickLook.
enum MediaBackend {
    // MARK: AVFoundation (MOV ↔ MP4, video → M4A)

    static func avExport(_ input: URL, to out: URL, preset: String, type: AVFileType) throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvError("This Mac can't export \(input.lastPathComponent) with that preset")
        }
        guard session.supportedFileTypes.contains(type) else {
            throw ConvError("This file can't be exported as .\(type.rawValue)")
        }
        session.outputURL = out
        session.outputFileType = type
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()
        guard session.status == .completed else {
            throw ConvError(session.error?.localizedDescription ?? "Export failed")
        }
    }

    /// Lossless rewrap when the codecs allow it, otherwise re-encode.
    static func avRewrap(_ input: URL, to out: URL, type: AVFileType) throws {
        do {
            try avExport(input, to: out, preset: AVAssetExportPresetPassthrough, type: type)
        } catch {
            try? FileManager.default.removeItem(at: out)
            try avExport(input, to: out, preset: AVAssetExportPresetHighestQuality, type: type)
        }
    }

    static func avToM4A(_ input: URL, to out: URL) throws {
        try avExport(input, to: out, preset: AVAssetExportPresetAppleM4A, type: .m4a)
    }

    // MARK: afconvert (audio → WAV / M4A / AIFF)

    static func afconvert(_ input: URL, to out: URL, ext: String) throws {
        let args: [String]
        switch ext {
        case "wav": args = ["-f", "WAVE", "-d", "LEI16"]
        case "aiff": args = ["-f", "AIFF", "-d", "BEI16"]
        case "m4a": args = ["-f", "m4af", "-d", "aac", "-b", "192000"]
        default: throw ConvError("afconvert can't write .\(ext)")
        }
        try Shell.run("/usr/bin/afconvert", args + [input.path, out.path])
    }

    // MARK: ffmpeg

    private static func ffmpeg(_ input: URL, to out: URL, args: [String]) throws {
        guard let exe = Tools.ffmpeg else { throw ConvError("DropWheel's video & audio tools aren't set up yet. Click the ◎ menu and choose “Finish setup…”.") }
        try Shell.run(exe, ["-n", "-hide_banner", "-loglevel", "error", "-i", input.path] + args + [out.path],
                      timeout: 3600)
    }

    private static func h264(faststart: Bool) -> [String] {
        var a = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-preset", "medium",
                 "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        if faststart { a += ["-movflags", "+faststart"] }
        return a
    }

    static func ffmpegConvert(_ input: URL, to out: URL, ext: String) throws {
        let src = Registry.normalize(input.pathExtension)
        switch ext {
        case "mp4":
            if ["mkv", "mov", "m4v", "ts", "3gp"].contains(src) {
                do { try ffmpeg(input, to: out, args: ["-c", "copy", "-movflags", "+faststart"]); return }
                catch { try? FileManager.default.removeItem(at: out) }
            }
            try ffmpeg(input, to: out, args: h264(faststart: true))
        case "mov":
            do { try ffmpeg(input, to: out, args: ["-c", "copy"]); return }
            catch { try? FileManager.default.removeItem(at: out) }
            try ffmpeg(input, to: out, args: h264(faststart: true))
        case "mkv":
            do { try ffmpeg(input, to: out, args: ["-c", "copy"]); return }
            catch { try? FileManager.default.removeItem(at: out) }
            try ffmpeg(input, to: out, args: h264(faststart: false))
        case "webm":
            try ffmpeg(input, to: out, args: ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"])
        case "gif":
            // First 30 s, 480 px wide, 12 fps: keeps GIFs from exploding in size.
            try ffmpeg(input, to: out, args: [
                "-t", "30", "-vf",
                "fps=12,scale=480:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                "-loop", "0",
            ])
        case "mp3": try ffmpeg(input, to: out, args: ["-vn", "-c:a", "libmp3lame", "-q:a", "2"])
        case "m4a": try ffmpeg(input, to: out, args: ["-vn", "-c:a", "aac", "-b:a", "192k"])
        case "wav": try ffmpeg(input, to: out, args: ["-vn", "-c:a", "pcm_s16le"])
        case "flac": try ffmpeg(input, to: out, args: ["-vn", "-c:a", "flac"])
        case "ogg": try ffmpeg(input, to: out, args: ["-vn", "-c:a", "libvorbis", "-q:a", "5"])
        case "webp": try ffmpeg(input, to: out, args: ["-c:v", "libwebp", "-q:v", "85", "-loop", "0"])
        case "png": try ffmpeg(input, to: out, args: ["-frames:v", "1"])
        case "jpg": try ffmpeg(input, to: out, args: ["-frames:v", "1", "-q:v", "2"])
        default: throw ConvError("ffmpeg recipe missing for .\(ext)")
        }
    }

    // MARK: SVG → PNG (QuickLook renderer, ships with macOS)

    static func svgToPNG(_ input: URL, to out: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Shell.run("/usr/bin/qlmanage", ["-t", "-s", "2048", "-o", tmp.path, input.path])
        let produced = tmp.appendingPathComponent(input.lastPathComponent + ".png")
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw ConvError("QuickLook couldn't render this SVG")
        }
        try FileManager.default.moveItem(at: produced, to: out)
    }
}
