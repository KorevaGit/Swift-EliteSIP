import AppKit
import MediaCore
import SwiftUI

/// Настройки, доступные без пароля.
///
/// **Граница проведена по вкладкам, а не по секциям** (решение M7c): всё, что
/// менеджер меняет сам, собрано здесь, а закрытое лежит за кнопкой
/// «Управление». Секционная граница была бы дешевле в правке, но размазанной:
/// каждая следующая настройка требовала бы отдельного решения, куда её
/// отнести, — и однажды это решение просто забыли бы принять.
///
/// **Одна страница, а не вкладки** — этап 2 плана по интерфейсу. Вкладки там
/// были записаны, когда секций было семь. После того как список профилей,
/// пометка, площадка и макросы уехали администратору, разделов осталось
/// четыре, и один из них — единственный переключатель темы. Четыре вкладки на
/// такой объём прячут настройку за кликом вместо того, чтобы показать её сразу:
/// критерий этапа — «поиск занимает один взгляд», и одна короткая страница
/// выполняет его строго лучше.
///
/// **Три размера текста, и только три.** Заголовок раздела — `.subheadline`
/// полужирным, всё содержимое строк — `.callout`, пояснения и производные
/// значения — `.footnote`. Кегль назначается блоку целиком, а не отдельным
/// надписям: до этого подписи строк были 12, подписи выключателей и значения
/// 13, и одинаковые по смыслу вещи стояли разным кеглем.
///
/// Размеры системные, а не числами. Числами они заданы в панели и в окне
/// входящего — те окна фиксированной ширины и висят поверх чужого интерфейса,
/// им расти нельзя; там девять разных кеглей, и каждый ярус говорит своим
/// голосом. Здесь окно обычное, и повторять эту россыпь незачем.
///
/// **Не `Form`.** Сгруппированная форма ставит непрозрачные плашки секций, и
/// сквозь них не видно материала окна — то есть прозрачность, ради которой всё
/// затевалось, пропадает. Отсюда ручная раскладка в две колонки: подпись слева
/// фиксированной шириной (`Theme.Metrics.settingsLabelColumn`), контрол справа.
/// Цена — выравнивание подписей приходится держать самим; она заплачена
/// сознательно.
///
/// Что здесь есть и почему именно это:
///
/// - **Устройства и эхоподавление** — меняются при смене наушников, то есть
///   чаще всего остального.
/// - **Рингтон вместе с заменой файла** — звук на своём рабочем месте человек
///   выбирает сам.
/// - **Самопроверка голоса** — ответ на «меня слышно?» без звонка коллеге.
/// - **Тема** — панель висит поверх CRM весь день, и если CRM светлая, а
///   система тёмная, выбор делает тот, кто на это смотрит.
/// - **«Исправить сеть»** — стук по портам по требованию, когда доступ
///   потерялся не по нашей логике.
/// - **Логи для техподдержки** — ради этого и делался M7a.
///
/// Чего здесь больше нет: выбор профиля переехал в капсулу панели, пометка и
/// площадка — администратору, ручное переключение «Офис/Удалённо» вырезано
/// (автоопределение осталось в бэкенде).
struct ManagerSettingsView: View {

    @EnvironmentObject private var model: AppModel

    /// Показывать ли окно ввода административного пароля.
    @State private var isAskingForPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            AudioSection()
            RingtoneSection()
            AppearanceSection()
            SupportSection()
            AdministrationRow(isAskingForPassword: $isAskingForPassword)
        }
        // Поля у краёв те же, что в панели: `contentPadding`. Разные отступы у
        // двух окон одного приложения читаются как небрежность, а не как
        // разница между окнами.
        //
        // Сверху — не они, а `Gap.titleToStatus`: там не край окна, а полоса
        // заголовка, и расстояние от светофора до первой строки в панели ровно
        // такое. С `contentPadding` настройки отъезжали от светофора втрое
        // дальше панели, и два окна выглядели собранными разными руками.
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.bottom, Theme.Metrics.contentPadding)
        .padding(.top, Theme.Gap.titleToStatus)
        .frame(width: Theme.Metrics.settingsWidth, alignment: .leading)
        // Мелкий размер управляющих элементов на всю страницу.
        //
        // Это и есть главный источник экономии высоты: обычный `Picker` в
        // macOS занимает 22 точки, мелкий — 17, и таких строк в окне полтора
        // десятка. Кегли при этом системные: ужимать заодно и текст значило бы
        // выиграть немного и потерять читаемость там, где её и так меряли.
        .controlSize(.small)
        // Материал заходит под полосу заголовка, а раскладка — нет, и это
        // разделение принципиально.
        //
        // При `.fullSizeContentView` окно отдаёт вёрстке всю высоту, но SwiftUI
        // отступает сверху на полосу заголовка безопасной зоной. Если
        // игнорировать её всей вёрсткой, размер окна перестаёт сходиться с
        // размером содержимого: `NSHostingController` считает идеальную высоту
        // с зоной, а рисуем мы без неё, и разница вылезает дырой внизу — у
        // прозрачного окна это сквозная щель со скруглением по краю.
        //
        // Поэтому зону игнорирует только фон. Содержимое встаёт под полосой
        // само, высота окна сходится, а материал накрывает и полосу — светофор
        // с названием лежат на нём, а не на чужом окне.
        //
        // Скругления у материала нет: окно прямоугольное, своё скругление
        // проступило бы углами поверх углов окна.
        .compatBackground {
            Color.clear
                .themedPanelSurface(cornerRadius: 0)
                .compatIgnoreSafeArea()
        }
        .sheet(isPresented: $isAskingForPassword) {
            AdminUnlockView(isPresented: $isAskingForPassword)
                .environmentObject(model)
        }
    }

}

// MARK: - Звук

private struct AudioSection: View {

    @EnvironmentObject private var model: AppModel
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []
    @State private var defaultInputName: String?
    @State private var defaultOutputName: String?
    @State private var observation: AudioDeviceCatalog.Observation?

    var body: some View {
        SettingsSection("Звук") {
            SettingsRow("Микрофон") {
                Picker("", selection: Binding(
                    get: { model.settings.audio.inputDeviceUID },
                    set: { model.settings.audio.inputDeviceUID = $0 }
                )) {
                    Text("Системный по умолчанию").tag(String?.none)
                    ForEach(inputs) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
            }

            // Что уйдёт в звонок на самом деле. «Системный по умолчанию» — это
            // правило, а не устройство, и ответ у него меняется вместе с
            // наушниками. Оператор спрашивает «через что меня будет слышно», и
            // название правила на этот вопрос не отвечает.
            if model.settings.audio.inputDeviceUID == nil, let defaultInputName {
                SettingsResolvedValue("в звонке: \(defaultInputName)")
            }

            SettingsRow("Наушники") {
                Picker("", selection: Binding(
                    get: { model.settings.audio.outputDeviceUID },
                    set: { model.settings.audio.outputDeviceUID = $0 }
                )) {
                    Text("Системные по умолчанию").tag(String?.none)
                    ForEach(outputs) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
            }

            if model.settings.audio.outputDeviceUID == nil, let defaultOutputName {
                SettingsResolvedValue("в звонке: \(defaultOutputName)")
            }

            // Появляется только когда обе стороны заданы явно и разными: тогда
            // движок собирает агрегатное устройство, а `VoiceProcessingIO`
            // агрегаты не принимает. Если хоть одна сторона отдана системе,
            // агрегата нет, эхоподавление работает, и говорить не о чем.
            //
            // Текст не обещает эха, и это правка после разбора макета. Эха не
            // будет ни в наушниках, ни в гарнитуре — там микрофон акустически
            // развязан с динамиком; эхо случается на колонках. Прежняя
            // формулировка пугала им всегда, то есть чаще всего впустую, и
            // набрана была красным.
            if needsAggregate {
                SettingsNote("""
                    Разные устройства: системного эхоподавления не будет. \
                    На колонках собеседник услышит себя, в наушниках — нет.
                    """)
            }

            // Эхоподавление как таковое не выключается: это системный
            // VoiceProcessingIO, и он либо есть, либо macOS его не даёт (разные
            // устройства). Выключателем остаётся автоусиление — единственное,
            // что в этом блоке действительно спорно на хорошей гарнитуре.
            SettingsToggleRow("Автоматическая регулировка усиления", isOn: Binding(
                get: { model.settings.audio.automaticGainControl },
                set: { model.settings.audio.automaticGainControl = $0 }
            ))

            SettingsToggleRow("Отпускать наушники между звонками", isOn: Binding(
                get: { model.settings.audio.releasesDeviceWhenIdle },
                set: { model.settings.audio.releasesDeviceWhenIdle = $0 }
            ))

            SettingsDivider()

            SettingsNote("Пять секунд записи и сразу воспроизведение — тем же трактом, что и разговор.")

            SettingsButtonsRow {
                if model.isSelfTestRunning {
                    Button("Остановить") { model.cancelVoiceSelfTest() }
                } else {
                    Button("Записать и прослушать") { model.startVoiceSelfTest() }
                        .disabled(!model.canStartSelfTest)
                }
            }

            if let status = selfTestStatus {
                SettingsNote(status)
            }
        }
        .onAppear {
            reloadDevices()
            observation = AudioDeviceCatalog.observe { _ in
                Task { @MainActor in reloadDevices() }
            }
        }
        .onDisappear {
            observation = nil
            // Уход с экрана обязан закрыть микрофон: иначе он остаётся открытым
            // до конца пяти секунд уже после того, как окно настроек закрыли.
            model.cancelVoiceSelfTest()
        }
    }

    /// Своё состояние самопроверки или причина, по которой она недоступна.
    ///
    /// Причина здесь, а не подсказкой при наведении: подсказок в интерфейсе
    /// больше нет, а «кнопка серая и молчит» — худший вид отказа.
    private var selfTestStatus: String? {
        if let status = model.selfTestStatus { return status }
        if model.isInCall { return "Во время разговора микрофон занят." }
        return nil
    }

    private var needsAggregate: Bool {
        AudioDeviceCatalog.needsAggregate(
            inputUID: model.settings.audio.inputDeviceUID,
            outputUID: model.settings.audio.outputDeviceUID
        )
    }

    private func reloadDevices() {
        inputs = model.inputDevices
        outputs = model.outputDevices
        defaultInputName = AudioDeviceCatalog.defaultInput?.name
        defaultOutputName = AudioDeviceCatalog.defaultOutput?.name
    }
}

// MARK: - Звонок

private struct RingtoneSection: View {

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
                SettingsNote(soundProblem, isAlarming: true)
            }
        }
        // Гаснет весь раздел, кроме собственного выключателя: он и есть то, чем
        // раздел возвращают.
        .disabled(!model.settings.ringtone.isEnabled)
        .onDisappear {
            // Иначе рингтон продолжает звонить после закрытия настроек, и
            // остановить его нечем.
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
        return model.settings.ringtone.customSoundURL == nil ? "\(name) — файл не найден" : name
    }

    /// Выбор файла.
    ///
    /// `NSOpenPanel`, а не `fileImporter`: тот появился в macOS 11, а срез
    /// x86_64 живёт с Catalina. Песочницы нет, поэтому обычного пути хватает —
    /// закладка безопасности не нужна.
    private func chooseSound() {
        model.stopRingtonePreview()

        let panel = NSOpenPanel()
        panel.title = "Звук входящего вызова"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["wav", "aiff", "aif", "caf", "m4a", "mp3"]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Ringtone.isPlayable(url: url) else {
            soundProblem = "Этот файл не читается как звук. Подойдут WAV, AIFF, CAF, M4A и MP3."
            return
        }
        soundProblem = nil
        model.settings.ringtone.customSoundPath = url.path
    }
}

// MARK: - Оформление

private struct AppearanceSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsSection("Оформление") {
            SettingsRow("Тема") {
                Picker("", selection: Binding(
                    get: { model.settings.appearance },
                    set: { model.settings.appearance = $0 }
                )) {
                    ForEach(AppearanceSetting.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
        }
    }
}

// MARK: - Техподдержка

/// Сюда же переехало «Исправить сеть» из бывшего «Рабочего места».
///
/// От той секции осталась одна кнопка: список профилей уехал в капсулу панели,
/// пометка и площадка — администратору. Одна кнопка раздела не образует, а по
/// смыслу она здесь и была: сеть чинят и логи собирают по одному поводу — «не
/// работает, звоню в поддержку».
private struct SupportSection: View {

    @EnvironmentObject private var model: AppModel

    @State private var archiveResult: String?

    var body: some View {
        SettingsSection("Техподдержка") {
            SettingsNote("""
                Архив с журналом и сведениями о системе: по нему в поддержке \
                разбирают, что случилось со звонком.
                """)

            SettingsButtonsRow {
                Button("Собрать логи") { makeArchive() }
                    .disabled(!model.settings.logFile.isEnabled)
                Button("Исправить сеть") {
                    Task { await model.repairNetwork() }
                }
            }

            if !model.settings.logFile.isEnabled {
                SettingsNote("Журнал в файл выключен — собирать нечего. Включается в «Управлении».")
            }

            if let archiveResult {
                SettingsNote(archiveResult)
            }

            if let status = model.networkRepairStatus {
                SettingsNote(status)
            }

            // Строки «Площадка» здесь нет. Она была задумана как «есть что
            // назвать в поддержке», но поддержка эти же сведения получает
            // архивом по соседней кнопке — и получает полнее. Строка на
            // чтение, которую оператор не понимает и не может изменить,
            // занимала место и объясняла себя только сама себе.
        }
    }

    private func makeArchive() {
        do {
            let url = try model.makeSupportArchive()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            archiveResult = "Готово: \(url.lastPathComponent)"
        } catch {
            archiveResult = "Не удалось собрать архив: \(error.localizedDescription)"
        }
    }
}

// MARK: - Дверь в «Управление»

/// Дверь в закрытую часть настроек.
///
/// Без заголовка раздела и последним блоком: это дверь не для менеджера. Он
/// должен её найти, если понадобится, а не спотыкаться о неё, меняя громкость.
///
/// **Состояния управления здесь больше нет.** Раньше блок показывал
/// `adminAccess.management` — «локальный режим» против «настройками управляет
/// EliteDash», — и показывал всегда, а не только когда состояние необычно
/// (пункт 3 роадмапа). Заменено на неизменную подпись «Режим администратора ·
/// Требуется пароль»: менеджеру нужно знать, что дверь заперта, а не кем она
/// заперта.
///
/// Цену стоит помнить: к M8 разницу между «управляет EliteDash» и «связь с ним
/// потерялась» станет неоткуда узнать, и место для неё придётся искать заново.
/// Скорее всего им окажется слот беды в панели — там уже живут остальные
/// «что-то не так с этой машиной».
private struct AdministrationRow: View {

    @Binding var isAskingForPassword: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.elementSpacing) {
            // Значок занимает колонку подписей: у этого блока подписи нет, но
            // левый край у страницы один на всех.
            CompatSymbol(name: "lock.shield.fill")
                .compatForeground(Theme.Palette.textSecondary)
                .frame(width: Theme.Metrics.settingsLabelColumn, alignment: .trailing)

            VStack(alignment: .leading, spacing: Theme.Metrics.hairSpacing) {
                Text("Режим администратора")
                // Предупреждение, а не объяснение. Перечислять, что именно
                // лежит за дверью, менеджеру незачем — он туда не идёт; а вот
                // знать, что дверь заперта, надо до нажатия, иначе запрос
                // пароля выглядит отказом.
                Text("Требуется пароль")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)
            }

            Spacer(minLength: Theme.Metrics.elementSpacing)

            // Обычная кнопка, а не акцентная: акцент на этой странице
            // принадлежит самопроверке и «Исправить сеть» — тому, чем менеджер
            // пользуется. Дорога к закрытым настройкам должна быть доступной, а
            // не заметной. Шеврон — потому что кнопка ведёт в другое окно.
            Button("Управление \u{203A}") { isAskingForPassword = true }
        }
        .font(.callout)
        .padding(Theme.Metrics.sectionSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedControlSurface(cornerRadius: Theme.Radius.surface)
    }
}

// MARK: - Кирпичи раскладки

/// Заголовок группы и плашка под её строками.
///
/// Заголовок над плашкой, а не внутри: так он читается как имя группы, а не
/// как её первая строка.
private struct SettingsSection<Content: View>: View {

    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            Text(title)
                .font(Font.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
                content
            }
            // Кегль задаётся блоку, а не каждой строке: так под него попадает
            // и то, о чём легко забыть, — значение рядом с ползунком, имя
            // файла рингтона, подписи кнопок.
            .font(.callout)
            .padding(Theme.Metrics.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Тот же слабый слой, что у клавиш панели: он полупрозрачен, и
            // материал под ним остаётся виден — иначе окно было бы стеклянным
            // только по краям.
            .themedControlSurface(cornerRadius: Theme.Radius.surface)
        }
    }
}

/// Строка «подпись — контрол».
private struct SettingsRow<Control: View>: View {

    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.elementSpacing) {
            Text(title)
                .frame(width: Theme.Metrics.settingsLabelColumn, alignment: .trailing)
            control
            Spacer(minLength: 0)
        }
    }
}

/// Выключатель. Подпись у него своя, поэтому левая колонка пустая: иначе
/// подпись стояла бы дважды.
private struct SettingsToggleRow: View {

    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        SettingsIndented {
            // Во всю оставшуюся ширину: тогда подпись начинается от колонки
            // контролов, как у всех прочих строк, а тумблер встаёт по правому
            // краю блока — и все тумблеры страницы стоят на одной вертикали.
            //
            // Подпись переносится, а не обрезается: «Автоматическая регулировка
            // усиле…» не сообщает ничего, а укорачивать саму настройку ради
            // двадцати точек ширины — менять смысл под вёрстку.
            Toggle(isOn: $isOn) {
                // Ширину забирает подпись, а не тумблер: иначе у переносящейся
                // подписи тумблер прижимается к ней вплотную и уезжает с той
                // вертикали, на которой стоят остальные.
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .compatSwitchToggle()
        }
    }
}

/// Пояснение или состояние — мелким, во второй колонке.
private struct SettingsNote: View {

    let text: String
    var isAlarming = false

    init(_ text: String, isAlarming: Bool = false) {
        self.text = text
        self.isAlarming = isAlarming
    }

    /// От колонки контролов, как всё остальное.
    ///
    /// Был заход пустить пояснения во всю ширину блока — ради высоты, когда
    /// окно не влезало в экран. Экономия вышла, но страница расслоилась на два
    /// левых края: подписи и контролы по одной вертикали, пояснения по другой.
    /// После сжатия окна высота перестала быть проблемой, и цена оказалась
    /// не нужна.
    var body: some View {
        SettingsIndented {
            Text(text)
                .font(.footnote)
                .compatForeground(isAlarming ? Theme.Palette.failure : Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Во что обернётся «системное по умолчанию». Не подпись и не пояснение: это
/// значение, просто вычисленное, — поэтому стоит в колонке контрола.
private struct SettingsResolvedValue: View {

    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        SettingsIndented {
            Text(text)
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
        }
    }
}

private struct SettingsButtonsRow<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        SettingsIndented {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                content
            }
        }
    }
}

/// Всё, у чего нет своей подписи, всё равно начинается от колонки контролов:
/// иначе страница расслаивается на два левых края.
private struct SettingsIndented<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.elementSpacing) {
            Color.clear.frame(width: Theme.Metrics.settingsLabelColumn, height: 1)
            content
            Spacer(minLength: 0)
        }
    }
}

/// Черта между устройствами и самопроверкой.
///
/// Не `Divider`: внутри `HStack` он становится вертикальным и схлопывается в
/// чёрточку. Здесь нужна линия поперёк, поэтому она задана прямоугольником.
private struct SettingsDivider: View {
    var body: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            Color.clear.frame(width: Theme.Metrics.settingsLabelColumn, height: 1)
            Rectangle()
                .fill(Theme.Palette.textTertiary)
                .frame(height: 1)
        }
    }
}
