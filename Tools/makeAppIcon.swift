// Рисует иконку приложения и раскладывает её по размерам `AppIcon.appiconset`.
//
// Запуск из корня проекта:
//   swift Tools/makeAppIcon.swift
//
// Скриптом, а не картинкой из редактора, по той же причине, по которой комплект
// символов лежит в SVG: знак пересобирается при каждой правке пропорций, и
// десять PNG, разошедшихся между собой на точку, потом не сведёт никто.
//
// **Что рисуется.** Полный фирменный знак: ломаная корона над дайлпадом. В доке
// места хватает и на девять отрезков короны, и на шесть клавиш, поэтому здесь
// знак стоит целиком — в отличие от строки меню, где от него остаётся силуэт
// короны, а место подставки занимает точка состояния (см.
// `StatusItemController`).

import AppKit
import Foundation

// MARK: - Палитра

/// Золото знака: три остановки, а не две. На двух градиент читается пластиком —
/// у металла светлая кромка сверху и глухой тон в тени.
let gold = [
    NSColor(calibratedRed: 0.91, green: 0.79, blue: 0.51, alpha: 1),
    NSColor(calibratedRed: 0.76, green: 0.57, blue: 0.23, alpha: 1),
    NSColor(calibratedRed: 0.55, green: 0.38, blue: 0.13, alpha: 1),
]

/// Подложка тёмная: золото на светлом теряет контраст, а иконка обязана
/// читаться и на светлых обоях, и в мелком размере переключателя окон.
let plate = [
    NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1),
]

// MARK: - Знак

/// Все числа — доли квадрата 1024, поэтому пропорции одинаковы во всех
/// размерах: масштаб задаётся один раз, снаружи.
private let canvas: CGFloat = 1024

/// Ломаная короны: три пика и две перекрёстные линии, как в фирменном знаке.
///
/// Знак целиком держится внутри безопасной зоны — от 195 до 760 по высоте.
/// Первый заход этой зоны не имел, и дайлпад уходил под скругление подложки:
/// нижний ряд отстоял от её края на восемь единиц из тысячи, а угол съедает
/// больше.
private func crownPath() -> CGMutablePath {
    let path = CGMutablePath()

    path.move(to: CGPoint(x: 223, y: 711))
    path.addLine(to: CGPoint(x: 364, y: 430))
    path.addLine(to: CGPoint(x: 512, y: 758))
    path.addLine(to: CGPoint(x: 660, y: 430))
    path.addLine(to: CGPoint(x: 801, y: 711))

    // Перекрестье — то, что отличает знак от обычной короны: линии уходят от
    // внешних концов к середине, пересекая соседние лучи.
    path.move(to: CGPoint(x: 223, y: 711))
    path.addLine(to: CGPoint(x: 512, y: 499))
    path.move(to: CGPoint(x: 801, y: 711))
    path.addLine(to: CGPoint(x: 512, y: 499))

    return path
}

/// Дайлпад: два ряда по три клавиши. Три ряда в знак не ставим — тогда корона
/// сжимается, а она в нём главная.
private func dialpadPath() -> CGMutablePath {
    let path = CGMutablePath()
    let radius: CGFloat = 30
    let columns: [CGFloat] = [372, 512, 652]
    // Нижний ряд стоит на 225: с радиусом 30 его край приходится на 195, то
    // есть на сто с лишним единиц выше кромки подложки — там, где скругление
    // угла уже ничего не отрезает.
    let rows: [CGFloat] = [320, 225]

    for y in rows {
        for x in columns {
            path.addEllipse(in: CGRect(
                x: x - radius, y: y - radius,
                width: radius * 2, height: radius * 2
            ))
        }
    }
    return path
}

/// Заливает путь золотом сквозь него самого.
///
/// Градиент кладётся на весь квадрат и обрезается фигурой, а не рисуется в
/// каждой детали заново: иначе у каждой клавиши свой переход от светлого к
/// тёмному, и знак рассыпается на шесть отдельных предметов.
private func fillWithGold(_ path: CGPath, stroke width: CGFloat?, in context: CGContext) {
    context.saveGState()
    context.addPath(path)

    if let width {
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        // Обводка превращается в заливку: `NSGradient` умеет заполнять область,
        // но не штрих, и без этой замены золото легло бы мимо линии.
        context.replacePathWithStrokedPath()
    }

    context.clip()
    NSGradient(colors: gold)?.draw(
        in: NSRect(x: 0, y: 0, width: canvas, height: canvas),
        angle: -90
    )
    context.restoreGState()
}

func makeIcon(side: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }

        context.scaleBy(x: side / canvas, y: side / canvas)

        // Поле вокруг подложки — доля, на которую системные иконки не доходят до
        // края: без него значок в доке выглядит крупнее соседей.
        let inset: CGFloat = 88
        let plateRect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
        // Скругление 22,37% стороны — системная доля macOS. При другой значок
        // читается наклейкой поверх чужой формы.
        let plateShape = CGPath(
            roundedRect: plateRect,
            cornerWidth: plateRect.width * 0.2237,
            cornerHeight: plateRect.width * 0.2237,
            transform: nil
        )

        context.saveGState()
        context.addPath(plateShape)
        context.clip()
        NSGradient(colors: plate)?.draw(
            in: NSRect(x: 0, y: 0, width: canvas, height: canvas),
            angle: -90
        )
        context.restoreGState()

        fillWithGold(crownPath(), stroke: 32, in: context)
        fillWithGold(dialpadPath(), stroke: nil, in: context)

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
