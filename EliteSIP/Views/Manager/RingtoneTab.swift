import AppKit
import MediaCore
import SwiftUI

/// Рингтон: играть ли, как громко, куда и чем.
///
/// Звук на своём рабочем месте человек выбирает сам — потому раздел и
/// менеджерский, а не административный.
struct RingtoneTab: View {

    @EnvironmentObject private var model: AppModel

    /// Что сказать про выбранный файл. Живёт до следующего выбора.
    @State private var soundProblem: String?

    var body: some View {
        SettingsSection("Звонок") {
            SettingsToggleRow("Проигрывать рингтон", isOn: Binding(
                get: { model.settings.ringtone.isEnabled },
                set: { model.settings.ringtone.isEnabled = $0 }
            ))

            SettingsRow("Громкость") {
                SettingSlider(
                    value: Binding(
                        get: { model.settings.ringtone.volume },
                        set: { model.settings.ringtone.volume = $0 }
                    ),
                    range: 0...1,
                    step: 0.05,
                    unit: nil
                )
                .frame(maxWidth: 200)
            }

            SettingsRow("Играть в") {
                Picker("", selection: Binding(
                    get: { model.settings.ringtone.usesSystemOutput },
                    set: { model.settings.ringtone.usesSystemOutput = $0 }
                )) {
                    Text("Системное устройство").tag(true)
                    Text("Устройство разговора").tag(false)
                }
                .labelsHidden()
            }

            // Гарнитура на столе звонка не слышна — тогда звонить должны
            // колонки. Раньше это было подсказкой при наведении; подсказок
            // больше нет, и объяснение стоит текстом.
            SettingsNote("Гарнитуру на столе не слышно — тогда звонить должны колонки.")

            SettingsRow("Звук") {
                Text(soundName)
                    .compatForeground(Theme.Palette.textSecondary)
            }

            SettingsButtonsRow {
                Button("Выбрать файл…") { chooseSound() }
                Button("Стандартный") {
                    model.settings.ringtone.customSoundPath = nil
                    soundProblem = nil
                }
                .disabled(model.settings.ringtone.customSoundPath == nil)
                Button(model.isRingtonePreviewPlaying ? "Остановить" : "Прослушать") {
                    model.toggleRingtonePreview()
                }
                .disabled(model.isInCall)
            }

            if let soundProblem {
                SettingsNote(verbatim: soundProblem, isAlarming: true)
            }
        }
        // Гаснет весь раздел, кроме собственного выключателя: он и есть то, чем
        // раздел возвращают.
        .disabled(!model.settings.ringtone.isEnabled)
        .onDisappear {
            // Иначе рингтон продолжает звонить после того, как раздел закрыли,
            // и остановить его нечем.
            model.stopRingtonePreview()
        }
    }

    private var soundName: String {
        guard let path = model.settings.ringtone.customSoundPath, !path.isEmpty else {
            return "Стандартный"
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        // Пропавший файл называется прямо: рингтон в этом случае молча вернётся
        // к стандартному, и человек должен понимать почему, а не слышать не то.
        guard model.settings.ringtone.customSoundURL == nil else { return name }
        return String(format: NSLocalizedString("%@ — файл не найден", comment: "рингтона нет на диске"), name)
    }

    /// Выбор файла.
    ///
    /// `NSOpenPanel`, а не `fileImporter`: тот появился в macOS 11, а срез
    /// x86_64 живёт с Catalina. Песочницы нет, поэтому обычного пути хватает —
    /// закладка безопасности не нужна.
    private func chooseSound() {
        model.stopRingtonePreview()

        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Звук входящего вызова", comment: "заголовок окна выбора файла")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["wav", "aiff", "aif", "caf", "m4a", "mp3"]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Ringtone.isPlayable(url: url) else {
            soundProblem = NSLocalizedString("Этот файл не читается как звук. Подойдут WAV, AIFF, CAF, M4A и MP3.", comment: "выбранный файл не годится в рингтоны")
            return
        }
        soundProblem = nil
        model.settings.ringtone.customSoundPath = url.path
    }
}
