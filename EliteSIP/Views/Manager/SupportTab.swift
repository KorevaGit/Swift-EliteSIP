import AppKit
import PanelLink
import SwiftUI

/// Логи для техподдержки.
///
/// **«Исправить сеть» отсюда ушла 19 августа 2026** — в новый раздел «Работа».
/// Стояла она здесь потому, что от бывшего «Рабочего места» осталась одна
/// кнопка, а одна кнопка раздела не образует. Раздел появился: кнопка открывает
/// дорогу до АТС снаружи, то есть чинит ровно ту работу из дома, которую
/// «Работа» и переключает, — и стоять ей надо там, где человек уже думает про
/// «я сегодня не в офисе», а не в соседстве со сбором логов.
struct SupportTab: View {

    @EnvironmentObject private var model: AppModel

    @State private var archiveResult: String?

    /// Ключ перепрошивки — то, что прислали при смене отдела.
    @State private var reflashKey = ""
    @State private var isApplyingKey = false
    @State private var reflashNotice: String?
    @State private var reflashFailed = false

    /// Версия и сборка одной строкой — тем же составом, что у администратора в
    /// «Диагностике». Две разные записи об одном и том же в двух окнах
    /// разошлись бы при первой правке, и поддержка узнавала бы номер сборки в
    /// зависимости от того, кто снял трубку.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        SettingsSection("Техподдержка") {
            SettingsNote("""
                Архив с журналом и сведениями о системе: по нему в поддержке \
                разбирают, что случилось со звонком.
                """)

            SettingsButtonsRow {
                Button("Собрать логи") { Task { await makeArchive() } }
                    .disabled(!model.settings.logFile.isEnabled)
            }

            if !model.settings.logFile.isEnabled {
                SettingsNote("Журнал в файл выключен — собирать нечего. Включается в «Управлении».")
            }

            if let archiveResult {
                SettingsNote(verbatim: archiveResult)
            }

            // Кнопка проверки обновлений (M7h). Не рядом со сбором логов
            // случайно: это тот же раздел «раз что-то не так — я это делаю
            // сам, не дожидаясь администратора», и «у меня старая версия» сюда
            // укладывается ровно так же, как «соберите мне архив».
            // Версия — прямо над кнопкой проверки, а не в отдельном разделе.
            //
            // Первое, что просит поддержка по телефону, — «какая у вас версия»,
            // и до этой правки менеджеру было нечего ответить: строка стояла
            // только в «Диагностике», за административным паролем. Соседство с
            // «Проверить обновления сейчас» тоже не случайное: человек видит
            // номер и тут же может выяснить, не устарел ли он.
            SettingsRow("Версия") {
                Text(verbatim: appVersion)
                    .compatForeground(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            UpdateCheckRow(isChecking: model.isCheckingForUpdates, result: model.updateCheckResult)

            // Поле ключа стоит здесь, а не в «Управлении», и это решение.
            //
            // Смена отдела перестала означать выезд к машине: администратор
            // выпускает ключ в панели, сотрудник вводит его сам — как вводил
            // при первой настройке. Административного пароля для этого не
            // требуется намеренно: пароль защищает настройки машины, а ключ
            // сам по себе есть право их сменить, и выдаёт его панель.
            //
            // Ключ привязан к этой машине: введённый на чужой, он уходит по
            // другому адресу и не находит ничего — вместо того чтобы сгореть на
            // проверке внутри пакета.
            SettingsSection("Новый ключ") {
                SettingsNote("""
                    Если вам прислали ключ для смены настроек — введите его здесь.                     Номер и настройки сменятся сами; переустанавливать ничего не нужно.
                    """)

                SettingsRow("Ключ") {
                    TextField("K7M2-9XQP-4TFB", text: $reflashKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isApplyingKey)
                        .frame(maxWidth: 260)
                }

                SettingsButtonsRow {
                    Button(isApplyingKey ? "Применяем…" : "Применить ключ") {
                        Task { await applyKey() }
                    }
                    .disabled(isApplyingKey || reflashKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let reflashNotice {
                    SettingsNote(verbatim: reflashNotice)
                }
            }

            // Строки «Площадка» здесь нет. Она была задумана как «есть что
            // назвать в поддержке», но поддержка эти же сведения получает
            // архивом по соседней кнопке — и получает полнее. Строка на
            // чтение, которую оператор не понимает и не может изменить,
            // занимала место и объясняла себя только сама себе.
        }
    }

    /// Забирает пакет по ключу и применяет — или откладывает до конца разговора.
    ///
    /// Отказ один на все случаи: не тот ключ, чужая машина, испорченный файл.
    /// Различать их вслух незачем — человеку все они означают «попросите новый
    /// ключ», а подбирающему подсказывали бы, какие адреса существуют.
    @MainActor
    private func applyKey() async {
        guard !isApplyingKey else { return }
        reflashNotice = nil
        reflashFailed = false

        let machine = model.settings.panel.installationID
        guard !machine.isEmpty else {
            reflashFailed = true
            reflashNotice = NSLocalizedString(
                "Это рабочее место поднимали не ключом — сменить настройки ключом нельзя.",
                comment: "перепрошивка на неактивированной машине")
            return
        }

        let parsed: ActivationKey
        do {
            parsed = try ActivationKey(input: reflashKey)
        } catch {
            reflashFailed = true
            reflashNotice = (error as? LocalizedError)?.errorDescription
                ?? PanelLinkError.malformedKey.errorDescription
            return
        }

        isApplyingKey = true
        defer { isApplyingKey = false }

        do {
            let package = try await ActivationService.fetch(key: parsed, installationID: machine)
            // Ключ к этому моменту уже сгорел — канал столбит пакет в момент
            // скачивания, — поэтому «применю позже» не бывает: либо сейчас,
            // либо по концу разговора.
            switch model.applyReflash(package) {
            case .applied:
                reflashKey = ""
                reflashNotice = NSLocalizedString(
                    "Готово: настройки рабочего места обновлены.",
                    comment: "перепрошивка применена")
            case .deferred:
                reflashKey = ""
                reflashNotice = NSLocalizedString(
                    "Принято: настройки применятся, как только вы положите трубку. Разговор не прервётся.",
                    comment: "перепрошивка отложена до конца разговора")
            }
        } catch {
            reflashFailed = true
            reflashNotice = (error as? LocalizedError)?.errorDescription
                ?? PanelLinkError.keyDidNotOpen.errorDescription
        }
    }

    private func makeArchive() async {
        do {
            let url = try await model.makeSupportArchive()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            archiveResult = String(format: NSLocalizedString("Готово: %@", comment: "архив для поддержки собран"), url.lastPathComponent)
        } catch {
            archiveResult = String(
                format: NSLocalizedString("Не удалось собрать архив: %@", comment: "архив для поддержки не собрался"),
                error.localizedDescription
            )
        }
    }
}
