import AppKit
import SwiftUI

/// Поле набора номера.
///
/// Не `TextField` из SwiftUI, и это не вкусовщина. От поля набора нужны четыре
/// вещи, и три из них SwiftUI на Catalina не даёт вовсе:
///
///   - **фокус при показе окна.** Панель открывают, чтобы позвонить, и клик по
///     полю перед набором — лишний жест. `@FocusState` появился в macOS 12;
///   - **Escape очищает поле.** Парный жест к Enter: без него номер стирают
///     backspace’ом по одной цифре. `onExitCommand` до текстового поля не
///     доходит — Escape съедает сам редактор;
///   - **стрелки вверх и вниз листают историю набора.** Перезвон — основной
///     способ исходящего звонка, и открывать ради него окно истории незачем;
///   - Enter звонит — единственное, что работало и раньше.
///
/// Всё это в AppKit — один делегат: `control(_:textView:doCommandBy:)` ловит
/// команды редактора до того, как их обработает он сам.
struct NumberField: NSViewRepresentable {

    @Binding var text: String

    var placeholder: String
    var fontSize: CGFloat
    /// Можно ли набирать. Без регистрации нельзя: набранный номер всё равно
    /// некуда отправить, а поле, принимающее ввод в никуда, обещает больше, чем
    /// приложение может.
    var isEnabled = true
    /// Забирать ли фокус при появлении. Только при появлении: перехватывать его
    /// на каждой перерисовке значило бы вырывать курсор у оператора из-под рук.
    var focusesOnAppear = true

    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Шаг по истории набора: `-1` — назад (стрелка вверх), `+1` — вперёд.
    var onHistoryStep: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        field.font = Self.font(size: fontSize)
        field.stringValue = text
        field.focusesOnAppear = focusesOnAppear
        field.isEnabled = isEnabled
        field.focusIfNeeded()
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        // Только когда значение правда разошлось: присваивание `stringValue`
        // сбрасывает выделение и позицию курсора, и делать это на каждой
        // перерисовке значит мешать набирать.
        if field.stringValue != text {
            field.stringValue = text
            // Число, не влезающее в поле, сдвигает видимую область текста
            // вправо. Присваивание `stringValue` эту прокрутку не снимает —
            // редактор остаётся смещён туда же, где стоял курсор перед
            // очисткой, и подсказка «Номер» рисуется от той же смещённой
            // точки, то есть обрезанной слева. Замер живого поля на Big Sur
            // 26 августа 2026: `scrollRangeToVisible` у самого редактора
            // это не лечит, а очистка крестиком к тому же часто приходит уже
            // без фокуса на поле, и тогда обращаться там вовсе не к чему.
            if text.isEmpty { resetScroll(of: field) }
        }
        field.font = Self.font(size: fontSize)
        field.placeholderString = placeholder
        field.isEnabled = isEnabled
        // Фокус берём и здесь: на запуске поле обычно ещё выключено —
        // регистрация не поднялась, — и момент, когда она поднимется,
        // приходится не на появление вида, а на любую следующую перерисовку.
        field.focusIfNeeded()
    }

    /// Снимает прокрутку однострочного поля, застрявшую от длинного номера.
    ///
    /// Помогает только полный пересбор сессии редактирования, а не
    /// `scrollRangeToVisible`: `abortEditing()` рвёт привязку к старому
    /// редактору без потери значения (оно уже присвоено строкой выше) — и на
    /// следующем фокусе AppKit создаёт редактор заново, с нулевой
    /// прокруткой. Фокус забирается следом безусловно, даже если поле перед
    /// очисткой его не держало: пустое поле набора и так просит фокус на
    /// появлении (см. `focusesOnAppear`), и после крестика оператор ждёт
    /// того же — курсора, готового принять новый номер, а не щелчка мимо.
    private func resetScroll(of field: NSTextField) {
        field.abortEditing()
        guard field.isEnabled, let window = field.window else { return }
        window.makeFirstResponder(field)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Начертание то же, что у `Theme.Text.dialedNumber`, только в терминах
    /// AppKit. Скруглённый рисунок появился в дескрипторах macOS 11 — на
    /// Catalina остаётся обычный системный, и это единственное, чем поле там
    /// отличается.
    private static func font(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .light)
        if #available(macOS 11.0, *),
           let descriptor = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: descriptor, size: size) {
            return rounded
        }
        return base
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {

        var parent: NumberField

        init(parent: NumberField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            // Модель нормализует номер у себя, и поле обязано показать
            // результат сразу же: иначе оператор видит скобки, которых на
            // сервер не уйдёт. Сравнение обязательно — без него курсор прыгал
            // бы в конец на каждом нажатии.
            if field.stringValue != parent.text { field.stringValue = parent.text }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onHistoryStep(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onHistoryStep(1)
                return true
            default:
                return false
            }
        }
    }
}

/// Текстовое поле, которое само становится первым ответчиком.
///
/// Ровно один раз: панель показывают, чтобы позвонить, но забирать фокус на
/// каждом движении интерфейса нельзя — оператор мог уйти в другое поле или в
/// другое окно.
///
/// «Один раз» считается от первого момента, когда фокус вообще можно взять:
/// на запуске поле выключено, пока не поднялась регистрация, а выключенному
/// полю фокус не даётся. Поэтому попытка повторяется, пока не удастся, и
/// прекращается сразу после.
final class FocusingTextField: NSTextField {

    var focusesOnAppear = true

    private var didFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    func focusIfNeeded() {
        guard focusesOnAppear, isEnabled, !didFocus, let window else { return }
        didFocus = true
        window.makeFirstResponder(self)
    }
}
