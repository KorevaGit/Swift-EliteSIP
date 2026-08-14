import AppKit
import SIPCore
import SwiftUI

/// Раздел «Предустановки»: сохранённые копии настроек рабочего места.
///
/// Отвечает на «как настроен такой-то отдел», а не «чьё это место». Снимается
/// один раз с настроенной машины, дальше на каждом следующем месте
/// администратор выбирает предустановку, вписывает номер — и получает готовое
/// место: кнопки, очереди, правила приёма, адрес АТС, стук, журнал.
///
/// Номера, пароля SIP и административного пароля в снимке нет — см.
/// `SettingsPreset`. Поэтому применение и спрашивает номер отдельно: без него
/// применять нечего.
struct PresetsTab: View {

    @EnvironmentObject private var model: AppModel

    @State private var newName = ""
    @State private var pendingRemoval: SettingsPreset?

    /// Что сказать после выгрузки: куда лёг файл или почему не лёг.
    @State private var notice: String?

    /// Что и куда применяем. Живёт здесь, а не в модели: до нажатия «Применить»
    /// это ещё не правка, а намерение, и «Отменить» ему не нужно.
    @State private var applyingID: UUID?
    @State private var number = ""
    @State private var targetID: UUID?

    var body: some View {
        SettingsSection("Снять с этой машины") {
            SettingsRow("Название") {
                TextField("Например: Менеджер", text: $newName)
            }

            SettingsButtonsRow {
                Button("Снять предустановку") { capture() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            SettingsNote("""
                Снимок берётся с того, что сейчас в окне, — включая несохранённое. \
                В него входит всё, кроме номера добавочного, пароля SIP и \
                административного пароля: предустановка ходит между машинами, а номер там \
                у каждой свой, и пароль, размноженный из шаблона, паролем быть перестаёт.
                """)
        }

        SettingsSection("Предустановки") {
            if model.settings.presets.isEmpty {
                SettingsNote("""
                    Пока ни одной. Настройте это рабочее место как образцовое и снимите с \
                    него предустановку — дальше её хватит, чтобы завести такое же место \
                    одним номером.
                    """)
            } else {
                ForEach(model.settings.presets) { preset in
                    presetCard(preset)
                }
            }

            if let notice {
                SettingsNote(verbatim: notice)
            }
        }
        .alert(item: $pendingRemoval) { preset in
            Alert(
                title: Text("Удалить «\(preset.name)»?"),
                message: Text("Настройки машин, заведённых по ней, останутся как есть."),
                primaryButton: .destructive(Text("Удалить")) { model.removePreset(preset.id) },
                secondaryButton: .cancel(Text("Оставить"))
            )
        }
    }

    // MARK: - Карточка

    @ViewBuilder
    private func presetCard(_ preset: SettingsPreset) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                TextField("", text: Binding(
                    get: { preset.name },
                    set: { model.renamePreset(preset.id, to: $0) }
                ))
                .frame(maxWidth: 220)

                Text(summary(of: preset))
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)

                Spacer(minLength: 0)

                Button(applyingID == preset.id ? "Не применять" : "Применить…") {
                    if applyingID == preset.id {
                        applyingID = nil
                    } else {
                        applyingID = preset.id
                        number = ""
                        targetID = nil
                    }
                }

                Button("Выгрузить…") { export(preset) }
                    .compatHelp("Сохранить файл предустановки — перенести её на другую машину")

                Button {
                    pendingRemoval = preset
                } label: {
                    CompatSymbol(name: "trash")
                }
                .buttonStyle(.plain)
                .compatHelp("Удалить предустановку")
            }

            if applyingID == preset.id {
                applyForm(preset)
            }
        }
    }

    /// Форма применения: куда и с каким номером.
    private func applyForm(_ preset: SettingsPreset) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            SettingsRow("Профиль") {
                Picker("", selection: $targetID) {
                    Text("Новый профиль").tag(UUID?.none)
                    ForEach(model.settings.profiles.profiles) { profile in
                        Text(title(of: profile)).tag(UUID?.some(profile.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            SettingsRow("Добавочный") {
                // Обычное поле, а не `NumberField`: тот собран для набора на
                // панели — забирает фокус при появлении и живёт по правилам
                // дайлпада. Здесь это строка настроек, как номер очереди рядом.
                TextField("номер", text: $number)
                    .frame(maxWidth: 120)
            }

            SettingsButtonsRow {
                Button("Применить") {
                    model.applyPreset(preset, number: number, to: targetID)
                    applyingID = nil
                }
                .compatProminentButtonStyle()
                .disabled(number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            SettingsNote("""
                Перезапишет всё, что входит в предустановку, — и настройки машины, и \
                выбранный профиль. Не тронет: номера и пароли остальных профилей, пароль \
                выбранного профиля и административный пароль. Логин добавочного \
                приравнивается к номеру.
                """)
        }
        .padding(.leading, Theme.Metrics.contentPadding)
    }

    // MARK: - Подписи

    private func summary(of preset: SettingsPreset) -> String {
        let account = preset.snapshot.profiles.active.account
        let macros = preset.snapshot.dtmf.macros.count
        let queues = preset.snapshot.queues.queues.count
        return "\(account.domain) · \(macros) макр. · \(queues) очер."
    }

    private func title(of profile: SIPProfile) -> String {
        let label = profile.label.isEmpty ? profile.account.username : profile.label
        return label.isEmpty ? "без номера" : label
    }

    /// Выгрузка предустановки файлом.
    ///
    /// Ради этого предустановки и заводились: настроить одно место, снять
    /// шаблон и разнести его по остальным. Внутри — тот же JSON, что и в
    /// настройках, и ровно так же без номера, пароля SIP и блока доступа: файл
    /// уезжает на чужую машину, и класть в него секреты нельзя тем более.
    private func export(_ preset: SettingsPreset) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(preset.name).elitesip-preset.json"
        panel.prompt = "Выгрузить"
        // Рабочий стол: оттуда файл переносят на флешку или прикладывают к
        // письму. Тот же выбор, что у выгрузки настроек в «Обслуживании».
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preset).write(to: url, options: .atomic)
            notice = "Предустановка выгружена в \(url.lastPathComponent)."
        } catch {
            notice = "Не удалось выгрузить: \(error.localizedDescription)"
        }
    }

    private func capture() {
        model.capturePreset(named: newName)
        newName = ""
    }
}
