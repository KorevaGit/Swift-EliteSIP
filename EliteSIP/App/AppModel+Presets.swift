import Foundation
import SIPCore

/// Предустановки: снять, применить, переименовать, удалить.
///
/// Отдельным файлом, как и административный режим: у предустановок свой
/// инвариант — снимок обязан ехать между машинами без номера и паролей, — и
/// держать эти четыре функции рядом дешевле, чем однажды найти пятую, которая
/// записала в шаблон чужой пароль.
///
/// Все правки ложатся в тот же черновик «Управления», что и остальное окно: на
/// диск не уходит ничего до «Сохранить», и «Отменить» возвращает как было.
extension AppModel {

    /// Снять предустановку с текущих настроек.
    ///
    /// С черновика, а не с диска: администратор настраивает место и снимает
    /// шаблон, не выходя из окна. Чистку делает сам `SettingsPreset` — здесь о
    /// том, что в снимок не входит, знать незачем.
    func capturePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.presets.append(SettingsPreset(name: trimmed, snapshot: settings))
        append(level: .info, message: "предустановка снята: \(trimmed)")
    }

    func renamePreset(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = settings.presets.firstIndex(where: { $0.id == id })
        else { return }
        settings.presets[index].name = trimmed
    }

    func removePreset(_ id: UUID) {
        guard let index = settings.presets.firstIndex(where: { $0.id == id }) else { return }
        let name = settings.presets[index].name
        settings.presets.remove(at: index)
        append(level: .info, message: "предустановка удалена: \(name)")
    }

    /// Применить предустановку: машинное — целиком, профилю — номер.
    ///
    /// - Parameters:
    ///   - preset: что применяем.
    ///   - number: номер добавочного; он же становится логином.
    ///   - password: пароль от него. `nil` или пустой — оставить как было.
    ///   - profileID: какому профилю. `nil` — завести новый.
    ///
    /// Что перезаписывается: всё, что есть в снимке, — макросы, очереди,
    /// правила приёма, АТС, стук, журнал, история, оформление. Что остаётся
    /// нетронутым: сами предустановки, административный пароль и пароль того
    /// профиля, к которому применяем. Пароль здесь не трогают намеренно —
    /// применение шаблона к настроенному месту не должно снимать его с линии.
    func applyPreset(
        _ preset: SettingsPreset,
        number: String,
        password: String? = nil,
        to profileID: UUID?
    ) {
        let trimmedNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)

        // Порядок важен: сперва машинная часть целиком, потом профили поверх
        // неё. В снимке профиль ровно один — шаблонный, — и оставить его как
        // есть значило бы стереть остальные профили машины.
        let keptPresets = settings.presets
        let keptCredential = settings.admin.credential
        let keptProfiles = settings.profiles

        settings = preset.snapshot
        settings.presets = keptPresets
        settings.admin.credential = keptCredential
        settings.profiles = keptProfiles

        let existing = profileID.flatMap { settings.profiles[$0] }
        var filled = preset.profile(number: trimmedNumber, keeping: existing)
        // Пароль приходит отдельно и только если его вписали: пустая строка из
        // формы не должна стирать пароль настроенного места.
        if let password, !password.isEmpty { filled.password = password }
        if let profileID, existing != nil {
            settings.profiles[profileID] = filled
        } else {
            _ = settings.profiles.add(filled)
        }

        append(
            level: .info,
            message: "предустановка применена: \(preset.name), добавочный \(trimmedNumber)"
        )
    }
}
