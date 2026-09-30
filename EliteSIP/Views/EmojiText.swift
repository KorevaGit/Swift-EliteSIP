import AppKit
import CoreText
import SwiftUI

/// Подпись со смайликами, которые видны и на старых macOS.
///
/// Шрифт Apple Color Emoji обновляется вместе с системой: на Catalina и
/// Big Sur самые новые смайлики рисуются квадратиками. Пикер в Спарке отдаёт
/// весь набор, поэтому те, что система нарисовать не умеет, подменяются
/// картинками из комплекта (`Emoji/`, тот же набор Apple). Всё, что система
/// рисует сама, остаётся обычным текстом: подпись без таких смайликов — один
/// `Text`, как и раньше.
struct EmojiText: View {
    let text: String
    let font: Font
    let size: CGFloat

    private var segments: [EmojiSegments.Segment] { EmojiSegments.split(text) }

    var body: some View {
        let parts = segments
        if parts.count == 1, case .text(let plain) = parts[0] {
            Text(plain).font(font)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let value):
                        Text(value).font(font)
                    case .image(let image):
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: size + 1, height: size + 1)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .compatAccessibilityLabel(verbatim: text)
        }
    }
}

enum EmojiSegments {
    enum Segment {
        case text(String)
        case image(NSImage)
    }

    static func split(_ text: String, renders: (String) -> Bool = systemRenders) -> [Segment] {
        var result: [Segment] = []
        var run = ""
        for character in text {
            let cluster = String(character)
            if isEmoji(character), !renders(cluster), let image = bundledImage(for: cluster) {
                if !run.isEmpty { result.append(.text(run)); run = "" }
                result.append(.image(image))
            } else {
                run += cluster
            }
        }
        if !run.isEmpty || result.isEmpty { result.append(.text(run)) }
        return result
    }

    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        if first.value < 0x80, !scalars.contains(where: { $0.value == 0x20E3 }) { return false }
        return scalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3 }
    }

    /// Умеет ли система нарисовать смайлик одним глифом шрифта Apple Color
    /// Emoji. Составной, который ей незнаком, распадается на несколько глифов,
    /// одиночный незнакомый уходит в запасной шрифт.
    static func systemRenders(_ cluster: String) -> Bool {
        let attributed = NSAttributedString(
            string: cluster,
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let line = CTLineCreateWithAttributedString(attributed)
        guard CTLineGetGlyphCount(line) == 1,
              let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1,
              let attributes = CTRunGetAttributes(runs[0]) as? [CFString: Any],
              let font = attributes[kCTFontAttributeName] else { return false }
        let name = CTFontCopyPostScriptName(font as! CTFont) as String
        return name.contains("AppleColorEmoji")
    }

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    private static func bundledImage(for cluster: String) -> NSImage? {
        let full = cluster.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_")
        let bare = cluster.unicodeScalars.filter { $0.value != 0xFE0F }
            .map { String($0.value, radix: 16) }.joined(separator: "_")
        for key in [full, bare] {
            if let cached = cache[key] { return cached }
            if let url = Bundle.main.url(forResource: "e-\(key)", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                cache[key] = image
                return image
            }
        }
        return nil
    }
}
