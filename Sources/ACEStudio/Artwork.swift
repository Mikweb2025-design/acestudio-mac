import SwiftUI
import AppKit
import AVFoundation

/// Procedural cover art: a mesh gradient whose palette follows the song's style
/// and whose shape is seeded by the track id, so every song gets its own cover.
struct Artwork: View {
    let seed: UUID
    let style: String
    var cornerRadius: CGFloat = 10
    var showGlyph = true
    var cover: URL? = nil
    var loading = false

    var body: some View {
        ZStack {
            if let cover, let img = CoverCache.shared.image(cover) {
                Image(nsImage: img).resizable().aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
            } else {
                procedural
            }
            if loading {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.black.opacity(0.35))
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var procedural: some View {
        let r = SeededRandom(seed)
        let palette = Artwork.palette(for: style, rnd: r)
        return GeometryReader { geo in
            ZStack {
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [Float(0.3 + r.next() * 0.4), 0], [1, 0],
                        [0, Float(0.3 + r.next() * 0.4)], [Float(0.25 + r.next() * 0.5), Float(0.25 + r.next() * 0.5)], [1, Float(0.3 + r.next() * 0.4)],
                        [0, 1], [Float(0.3 + r.next() * 0.4), 1], [1, 1],
                    ],
                    colors: (0..<9).map { palette[($0 + Int(r.next() * 10)) % palette.count] }
                )
                // soft light orbs
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(0.10 + 0.08 * Double(i)))
                        .frame(width: geo.size.width * (0.25 + r.next() * 0.5))
                        .position(x: geo.size.width * r.next(), y: geo.size.height * r.next())
                        .blur(radius: geo.size.width * 0.12)
                }
                if showGlyph {
                    Image(systemName: Artwork.glyph(for: style))
                        .font(.system(size: geo.size.width * 0.28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.25), radius: geo.size.width * 0.04)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    static func palette(for style: String, rnd: SeededRandom) -> [Color] {
        let s = style.lowercased()
        let table: [(keys: [String], colors: [Color])] = [
            (["rock", "metal", "punk", "grunge"], [.red, .black, .orange, Color(red: 0.4, green: 0, blue: 0)]),
            (["lo-fi", "lofi", "chill", "ambient", "dream"], [.purple, .indigo, .teal, Color(red: 0.95, green: 0.7, blue: 0.8)]),
            (["jazz", "blues", "soul", "bossa"], [Color(red: 0.55, green: 0.3, blue: 0.1), .orange, .brown, Color(red: 0.1, green: 0.15, blue: 0.3)]),
            (["house", "techno", "edm", "dance", "trance", "electro"], [.cyan, .blue, .purple, .pink]),
            (["hip hop", "hip-hop", "trap", "rap", "drill"], [.black, .yellow, .orange, Color(red: 0.2, green: 0.2, blue: 0.25)]),
            (["summer", "sunny", "beach", "reggaeton", "latin", "tropical"], [.orange, .yellow, .pink, .teal]),
            (["ballad", "piano", "acoustic", "folk", "singer-songwriter"], [Color(red: 0.95, green: 0.85, blue: 0.7), .brown, .teal, .indigo]),
            (["orchestral", "cinematic", "epic", "classical"], [Color(red: 0.05, green: 0.1, blue: 0.3), .indigo, Color(red: 0.85, green: 0.7, blue: 0.3), .black]),
            (["synthwave", "80s", "retro", "disco"], [.pink, .purple, .orange, .cyan]),
        ]
        for row in table where row.keys.contains(where: { s.contains($0) }) { return row.colors }
        let h = rnd.next()   // String.hashValue changes every launch, so use the stable seed
        return [
            Color(hue: h, saturation: 0.75, brightness: 0.9),
            Color(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.7),
            Color(hue: (h + 0.55).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.85),
            Color(hue: (h + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 0.35),
        ]
    }

    static func glyph(for style: String) -> String {
        let s = style.lowercased()
        if s.contains("piano") { return "pianokeys" }
        if s.contains("guitar") || s.contains("rock") { return "guitars.fill" }
        if s.contains("orchestr") || s.contains("cinematic") { return "music.quarternote.3" }
        if s.contains("instrumental") { return "waveform" }
        if s.contains("vocal") || s.contains("voice") { return "music.mic" }
        return "music.note"
    }
}

/// Deterministic pseudo-random sequence from a UUID (stable cover per song).
final class SeededRandom {
    private var state: UInt64
    init(_ id: UUID) {
        let u = id.uuid
        state = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7].reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

/// Decoded cover images (a 1024 px PNG decoded once, reused by every view).
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private var images: [URL: NSImage] = [:]

    func image(_ url: URL) -> NSImage? {
        if let i = images[url] { return i }
        guard let i = NSImage(contentsOf: url) else { return nil }
        images[url] = i
        return i
    }

    func invalidate(_ url: URL) { images[url] = nil }
}

// MARK: - Waveform

@MainActor
@Observable
final class WaveformCache {
    static let shared = WaveformCache()
    private(set) var peaks: [URL: [Float]] = [:]
    private var loading: Set<URL> = []

    func peaks(for url: URL) -> [Float]? {
        if let p = peaks[url] { return p }
        guard !loading.contains(url) else { return nil }
        loading.insert(url)
        Task.detached(priority: .utility) {
            let p = WaveformCache.compute(url, bins: 160)
            await MainActor.run { self.peaks[url] = p; self.loading.remove(url) }
        }
        return nil
    }

    nonisolated static func compute(_ url: URL, bins: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let total = AVAudioFrameCount(file.length)
        let per = max(total / AVAudioFrameCount(bins), 1)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: per) else { return [] }
        var out: [Float] = []
        for _ in 0..<bins {
            do { try file.read(into: buf, frameCount: per) } catch { break }
            guard let ch = buf.floatChannelData?[0] else { break }
            var peak: Float = 0
            let n = Int(buf.frameLength)
            var i = 0
            while i < n { peak = max(peak, abs(ch[i])); i += 8 }
            out.append(peak)
        }
        let m = out.max() ?? 1
        return out.map { $0 / max(m, 0.001) }
    }
}

struct WaveformView: View {
    let url: URL
    var progress: Double = 0           // 0...1
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        let peaks = WaveformCache.shared.peaks(for: url) ?? []
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !peaks.isEmpty else {
                    ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)), with: .color(.secondary.opacity(0.3)))
                    return
                }
                let w = size.width / CGFloat(peaks.count)
                for (i, p) in peaks.enumerated() {
                    let h = max(2, CGFloat(p) * size.height)
                    let rect = CGRect(x: CGFloat(i) * w + w * 0.15, y: (size.height - h) / 2, width: w * 0.7, height: h)
                    let played = Double(i) / Double(peaks.count) < progress
                    ctx.fill(Path(roundedRect: rect, cornerRadius: w * 0.35),
                             with: .color(played ? .accentColor : .secondary.opacity(0.35)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek?(min(max(v.location.x / geo.size.width, 0), 1))
            })
        }
    }
}
