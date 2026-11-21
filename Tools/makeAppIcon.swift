// Рисует иконку приложения и раскладывает её по размерам `AppIcon.appiconset`.
//
// Запуск из корня проекта:
//   swift Tools/makeAppIcon.swift
//
// Скриптом, а не картинкой из редактора, по той же причине, по которой комплект
// символов лежит в SVG: знак пересобирается при каждой правке пропорций, и
// десять PNG, разошедшихся между собой на точку, потом не сведёт никто.
//
// **Что рисуется.** Знак «Шампань» (с Windows-клиентом 1.0.1): корона над
// гарнитурой контуром шампанского цвета на графитовой подложке. В строке меню
// тот же контур без подложки (см. `StatusItemController`).

import AppKit
import Foundation

// MARK: - Знак «Шампань»

// Тот же вектор, что `EliteSIP/Theme/BrandMark.swift` и `BrandLogo` в
// Windows-клиенте: контур шампанского цвета (#D8C6A5) на графитовой подложке.
// Скрипт запускается отдельно от приложения, поэтому геометрия повторена.

private let canvas: CGFloat = 1024

private func markPath(in rect: CGRect) -> CGPath {
    let scale = rect.width / 32
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * scale, y: rect.minY + (32 - y) * scale)
    }
    let path = CGMutablePath()
    path.move(to: p(7, 12))
    for (x, y) in [(5, 5), (11, 8), (16, 3), (21, 8), (27, 5), (25, 12)] as [(CGFloat, CGFloat)] {
        path.addLine(to: p(x, y))
    }
    path.move(to: p(7, 16))
    path.addCurve(to: p(25, 16), control1: p(7, 12), control2: p(25, 12))
    path.addLine(to: p(25, 22))
    path.addQuadCurve(to: p(19, 28), control: p(25, 28))
    path.addLine(to: p(17, 28))
    path.move(to: p(7, 16))
    path.addLine(to: p(7, 21))
    path.addQuadCurve(to: p(13, 29), control: p(7, 27))
    path.move(to: p(4, 16))
    path.addQuadCurve(to: p(1, 20), control: p(1, 16))
    path.addQuadCurve(to: p(4, 24), control: p(1, 24))
    path.move(to: p(28, 16))
    path.addQuadCurve(to: p(31, 20), control: p(31, 16))
    path.addQuadCurve(to: p(28, 24), control: p(31, 24))
    return path
}

func makeIcon(side: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.scaleBy(x: side / canvas, y: side / canvas)

        // Поле вокруг подложки — сетка иконок macOS: без него значок в доке
        // выглядит крупнее соседей.
        let inset: CGFloat = 88
        let plateRect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
        let unit = plateRect.width / 32
        // Скругление 22,37% стороны — системная доля macOS.
        let plateShape = CGPath(
            roundedRect: plateRect,
            cornerWidth: plateRect.width * 0.2237,
            cornerHeight: plateRect.width * 0.2237,
            transform: nil
        )

        // Графит: сверху #383C40, снизу #23262A — как у Windows-клиента.
        context.saveGState()
        context.addPath(plateShape)
        context.clip()
        NSGradient(colors: [
            NSColor(srgbRed: 56 / 255, green: 60 / 255, blue: 64 / 255, alpha: 1),
            NSColor(srgbRed: 35 / 255, green: 38 / 255, blue: 42 / 255, alpha: 1),
        ])?.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: -90)
        context.restoreGState()

        // Тонкая светлая кромка отделяет подложку от тёмных обоев.
        context.addPath(plateShape)
        context.setStrokeColor(NSColor(white: 1, alpha: 40 / 255).cgColor)
        context.setLineWidth(0.35 * unit)
        context.strokePath()

        // Знак — в квадрате со стороной 3/4 подложки, отступ 4 единицы.
        let markRect = CGRect(x: plateRect.minX + 4 * unit, y: plateRect.minY + 4 * unit,
                              width: 24 * unit, height: 24 * unit)
        context.addPath(markPath(in: markRect))
        context.setStrokeColor(NSColor(srgbRed: 216 / 255, green: 198 / 255, blue: 165 / 255, alpha: 1).cgColor)
        context.setLineWidth(2.3 * 0.75 * unit)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        return true
    }
}

// MARK: - Раскладка по файлам

func png(_ image: NSImage, side: CGFloat) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    bitmap.size = NSSize(width: side, height: side)
    return bitmap.representation(using: .png, properties: [:])
}

let root = FileManager.default.currentDirectoryPath
let target = "\(root)/EliteSIP/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)

/// Пары «сторона в точках — множитель»: набор macOS, от значка в списке до
/// витрины App Store.
let variants: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

var entries: [String] = []

for variant in variants {
    let pixels = CGFloat(variant.point * variant.scale)
    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let name = "icon_\(variant.point)x\(variant.point)\(suffix).png"

    guard let data = png(makeIcon(side: pixels), side: pixels) else {
        print("не удалось нарисовать \(name)")
        exit(1)
    }
    try? data.write(to: URL(fileURLWithPath: "\(target)/\(name)"))

    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(variant.scale)x",
          "size" : "\(variant.point)x\(variant.point)"
        }
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try? contents.write(toFile: "\(target)/Contents.json", atomically: true, encoding: .utf8)

print("готово: \(variants.count) файлов в AppIcon.appiconset")
