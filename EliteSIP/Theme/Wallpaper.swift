import AppKit
import CoreImage
import SwiftUI

/// Фоновые обои окон — как у Windows-клиента 1.0.4 (`BackgroundImages`,
/// `WindowBackgroundService`).
///
/// Картинка копируется к настройкам (`window-background.png`): удалённый или
/// переименованный исходник не должен оставить окно без фона. Обрабатывается
/// только изображение — размытие и яркость; текст и кнопки поверх него не
/// трогаются, а поверхности становятся полупрозрачными по выбору оператора.
struct BackgroundSettings: Codable, Sendable, Equatable {

    enum Transparency: String, Codable, Sendable, CaseIterable, Identifiable {
        case off, light, medium, strong

        var id: String { rawValue }

        /// Непрозрачность графитовых поверхностей поверх обоев.
        var surfaceOpacity: Double {
            switch self {
            case .off: 1
            case .light: 0.85
            case .medium: 0.7
            case .strong: 0.5
            }
        }
    }

    /// Есть ли обои: файл сохранён к настройкам.
    var isEnabled: Bool = false
    /// Масштаб, %: 50–200.
    var scale: Int = 100
    /// Размытие, точек: 0–24.
    var blur: Int = 8
    /// Яркость, %: 30–170.
    var brightness: Int = 100
    var transparency: Transparency = .off
    /// Тема «Цвета обоев», как в Windows 1.0.4: нейтральные поверхности
    /// перекрашиваются в преобладающий цвет картинки, палитра — тёмная.
    ///
    /// Флагом здесь, а не значением `AppearanceSetting`: прежние версии
    /// читают тот же файл и на незнакомой теме теряли бы настройки целиком,
    /// а неизвестное поле этого блока они просто пропускают.
    var tintsInterface: Bool = false

    static let scaleRange = 50...200
    static let blurRange = 0...24
    static let brightnessRange = 30...170

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        scale = (try c.decodeIfPresent(Int.self, forKey: .scale) ?? 100).clamped(to: Self.scaleRange)
        blur = (try c.decodeIfPresent(Int.self, forKey: .blur) ?? 8).clamped(to: Self.blurRange)
        brightness = (try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 100).clamped(to: Self.brightnessRange)
        transparency = (try? c.decodeIfPresent(Transparency.self, forKey: .transparency)).flatMap { $0 } ?? .off
        tintsInterface = (try? c.decodeIfPresent(Bool.self, forKey: .tintsInterface)).flatMap { $0 } ?? false
    }

    /// Где лежит сохранённая копия.
    static var storedURL: URL {
        SettingsStore.fileURL.deletingLastPathComponent().appendingPathComponent("window-background.png")
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// Чтение, проверка и обработка картинки обоев.
@MainActor
enum Wallpaper {

    enum ImportError: LocalizedError {
        case tooLarge, unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge: NSLocalizedString("Картинка больше 30 МБ", comment: "обои не приняты")
            case .unreadable: NSLocalizedString("Файл не похож на картинку", comment: "обои не приняты")
            }
        }
    }

    /// Пределы — как у Windows-клиента: 30 МБ файла, 100 Мп кадра, 1600 точек
    /// по большей стороне после уменьшения.
    private static let maximumFileBytes = 30 * 1024 * 1024
    private static let maximumPixels = 100_000_000
    private static let maximumSide: CGFloat = 1600

    /// Декодирует картинку до замены файла: битая картинка не уничтожает
    /// прежний фон.
    static func importImage(from source: URL) throws {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumFileBytes else { throw ImportError.tooLarge }
        guard let image = NSImage(contentsOf: source),
              let bitmap = image.representations.first as? NSBitmapImageRep ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              bitmap.pixelsWide * bitmap.pixelsHigh <= maximumPixels,
              let cg = bitmap.cgImage
        else { throw ImportError.unreadable }

        let ci = CIImage(cgImage: cg)
        let longest = max(ci.extent.width, ci.extent.height)
        let factor = min(1, maximumSide / max(longest, 1))
        let reduced = ci.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let out = context.createCGImage(reduced, from: reduced.extent),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
        else { throw ImportError.unreadable }

        let destination = BackgroundSettings.storedURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination, options: .atomic)
        cache.removeAll()
        original = nil
        dominant = nil
    }

    static func remove() {
        try? FileManager.default.removeItem(at: BackgroundSettings.storedURL)
        cache.removeAll()
        original = nil
        dominant = nil
    }

    private static var dominant: NSColor??

    /// Преобладающий цвет картинки — `SampleColor` Windows: кадр ужимается до
    /// 16×16, пиксели раскладываются по корзинам 8×8×8, побеждает самая тяжёлая.
    static func dominantColor() -> NSColor? {
        if let dominant { return dominant }
        let result = sampleDominantColor()
        dominant = .some(result)
        return result
    }

    private static func sampleDominantColor() -> NSColor? {
        guard let source = CIImage(contentsOf: BackgroundSettings.storedURL),
              source.extent.width > 0, source.extent.height > 0
        else { return nil }
        let side = 16
        let tiny = source.transformed(by: CGAffineTransform(
            scaleX: CGFloat(side) / source.extent.width,
            y: CGFloat(side) / source.extent.height
        ))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        context.render(
            tiny,
            toBitmap: &pixels,
            rowBytes: side * 4,
            bounds: CGRect(x: tiny.extent.minX, y: tiny.extent.minY, width: CGFloat(side), height: CGFloat(side)),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        var groups: [Int: (r: Int, g: Int, b: Int, weight: Int)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b, a) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
            let key = (r / 32) << 6 | (g / 32) << 3 | b / 32
            let group = groups[key] ?? (0, 0, 0, 0)
            groups[key] = (group.r + r * a, group.g + g * a, group.b + b * a, group.weight + a)
        }
        guard let top = groups.values.max(by: { $0.weight < $1.weight }), top.weight > 0 else { return nil }
        return NSColor(
            srgbRed: CGFloat(top.r / top.weight) / 255,
            green: CGFloat(top.g / top.weight) / 255,
            blue: CGFloat(top.b / top.weight) / 255,
            alpha: 1
        )
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static var original: CIImage?
    private static var cache: [String: NSImage] = [:]

    /// Обработанная картинка: размытие и яркость. Кэш по параметрам —
    /// перерисовка окна не пересчитывает фильтры.
    static func image(blur: Int, brightness: Int) -> NSImage? {
        let key = "\(blur)-\(brightness)"
        if let cached = cache[key] { return cached }
        if original == nil {
            original = CIImage(contentsOf: BackgroundSettings.storedURL)
        }
        guard let source = original else { return nil }

        var image = source.clampedToExtent()
        if blur > 0 {
            image = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
        }
        // Яркость — множителем, а не сдвигом: 100 % — исходник, 30 % — почти
        // ночь, 170 % — выцветший день. Сдвиг `CIColorControls` выжигал тени.
        let factor = CGFloat(brightness) / 100
        image = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
        ])
        image = image.cropped(to: source.extent)
        guard let cg = context.createCGImage(image, from: source.extent) else { return nil }
        let result = NSImage(cgImage: cg, size: source.extent.size)
        if cache.count > 4 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

/// Непрозрачность графитовых поверхностей поверх обоев — см. `BackgroundSettings.Transparency`.
/// `nil` — обоев нет, поверхности следуют оформлению окна (стекло или нет).
private struct SurfaceOpacityKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

/// Цвет темы «Цвета обоев»; `nil` — поверхности обычного графита.
private struct GraphiteTintKey: EnvironmentKey {
    static let defaultValue: NSColor? = nil
}

extension EnvironmentValues {
    var graphiteTint: NSColor? {
        get { self[GraphiteTintKey.self] }
        set { self[GraphiteTintKey.self] = newValue }
    }

    var graphiteSurfaceOpacity: Double? {
        get { self[SurfaceOpacityKey.self] }
        set { self[SurfaceOpacityKey.self] = newValue }
    }
}

/// Обои под содержимым окна: заполняют его целиком, масштаб — от центра.
struct WallpaperLayer: View {

    let settings: BackgroundSettings

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            if let image = Wallpaper.image(blur: settings.blur, brightness: settings.brightness) {
                let fill = max(
                    geometry.size.width / max(image.size.width, 1),
                    geometry.size.height / max(image.size.height, 1)
                ) * CGFloat(settings.scale) / 100
                Image(nsImage: image)
                    .resizable()
                    .frame(width: image.size.width * fill, height: image.size.height * fill)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        // Подложка под текст: в светлой теме тёмные подписи над тёмными обоями
        // не читались вовсе. Светлая — молочная, тёмная — лёгкое затемнение;
        // картинка остаётся видна, а текст получает свой контраст.
        .compatOverlay {
            (scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.62))
        }
        .clipped()
        .compatAccessibilityHidden(true)
    }
}

extension View {

    /// Обои под окном, если они выбраны, и прозрачность поверхностей поверх них.
    @ViewBuilder
    func wallpaperBackground(_ settings: BackgroundSettings) -> some View {
        if settings.isEnabled {
            self
                .environment(\.graphiteSurfaceOpacity, settings.transparency.surfaceOpacity)
                .environment(\.graphiteTint, settings.tintsInterface ? Wallpaper.dominantColor() : nil)
                .compatBackground { WallpaperLayer(settings: settings).compatIgnoreSafeArea() }
        } else {
            self
        }
    }
}

/// Текущие обои для всех окон. Зеркало `settings.background`: окна вроде
/// входящего не знают о модели, а обои обязаны быть одинаковыми везде.
@MainActor
final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()
    @Published var settings = BackgroundSettings()
}

/// Обои под содержимым окна — на всех экранах, как в Windows 1.0.4.
/// Нативный сайдбар обоями не накрывается: его материал рисует система.
struct WallpaperHost<Content: View>: View {

    @ObservedObject private var store = WallpaperStore.shared
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.wallpaperBackground(store.settings)
    }
}
