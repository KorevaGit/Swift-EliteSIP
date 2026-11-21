import AppKit
import SwiftUI

/// Тема приложения и корпус окон.
///
/// Раздел был из одной строки, и это не считалось недосмотром: панель софтфона
/// висит поверх CRM весь день, и если CRM светлая, а система тёмная, выбор
/// делает тот, кто на это смотрит. Прятать эту строку внутрь соседнего раздела
/// было нельзя — «Тема» не ищется ни в «Звуке», ни в «Техподдержке».
///
/// **«Без стекла» переехало сюда из «Диагностики» «Управления».** Дублировать
/// его было нельзя: одна настройка в двух окнах — это два текста про один
/// выключатель, и разойдутся они на первой же правке. А выбор между двумя было
/// на чём делать: закрытым переключатель стоял среди сведений о сборке, где
/// объяснял сам себя приборной строкой «Liquid Glass доступен», — а меняет он
/// ровно то же, что и тема, и по той же причине: смотрит на это тот, кто сидит
/// за машиной. В «Диагностике» осталась строка про доступность стекла: это
/// сведения о сборке, а не настройка.
struct AppearanceTab: View {

    @EnvironmentObject private var model: AppModel

    /// Что именно собираются переключить.
    ///
    /// Один вопрос на две настройки, а не два `.alert` на одной вью: второй
    /// такой модификатор в цепочке ненадёжен, а спрашивают они об одном и том
    /// же — согласны ли на перезапуск со снятием регистрации.
    private enum PendingRestart: Identifiable {

        case chrome
        case language(LanguageSetting)

        var id: String {
            switch self {
            case .chrome: return "chrome"
            case .language(let language): return "language-\(language.rawValue)"
            }
        }
    }

    @State private var pendingRestart: PendingRestart?

    /// Темы в переключателе: три системные и «Цвета обоев», как в Windows 1.0.4.
    /// Последняя видна, только когда обои выбраны: красить интерфейс не во что.
    private enum ThemeChoice: String, CaseIterable, Identifiable {
        case system, light, dark, wallpaper
        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: AppearanceSetting.system.title
            case .light: AppearanceSetting.light.title
            case .dark: AppearanceSetting.dark.title
            case .wallpaper: NSLocalizedString("Цвета обоев", comment: "тема оформления")
            }
        }
    }

    private var hasWallpaper: Bool { model.settings.background.isEnabled }

    private var themeChoice: ThemeChoice {
        if hasWallpaper && model.settings.background.tintsInterface { return .wallpaper }
        switch model.settings.appearance {
        case .system: return .system
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Тема обоев — тёмная палитра плюс перекраска поверхностей, как в Windows.
    private func choose(_ choice: ThemeChoice) {
        var settings = model.settings
        settings.background.tintsInterface = choice == .wallpaper
        switch choice {
        case .system: settings.appearance = .system
        case .light: settings.appearance = .light
        case .dark, .wallpaper: settings.appearance = .dark
        }
        model.settings = settings
    }

    /// Есть ли стекло в самой системе. Ниже macOS 26 переключать нечего:
    /// приложение и так показано обычным, и включить стекло там, где его нет,
    /// выключатель не может.
    private var isGlassAvailable: Bool { Theme.Chrome.isGlassAvailable }

    var body: some View {
        SettingsSection("Тема", icon: "panels-top-left") {
            SettingsRow("Тема") {
                Picker("", selection: Binding(
                    get: { themeChoice },
                    set: { choose($0) }
                )) {
                    ForEach(ThemeChoice.allCases.filter { $0 != .wallpaper || hasWallpaper }) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // По левому краю — та же правка, что у уровней журнала в
                // «Диагностике»: по центру сегменты уезжают правее колонки
                // контролов.
                .frame(maxWidth: hasWallpaper ? 340 : 220, alignment: .leading)
            }

            SettingsDivider()

            // Переключение не правит настройку, а спрашивает: корпус выбирается
            // при сборке окон, и сменить его можно только вместе с
            // перезапуском. Поэтому сам тумблер показывает текущее состояние, а
            // щелчок по нему открывает вопрос — и до ответа не меняется ничего.
            SettingsToggleRow("Без стекла", isOn: Binding(
                get: { model.settings.plainChrome },
                set: { _ in pendingRestart = .chrome }
            ))
            .disabled(!isGlassAvailable)

            SettingsNote(
                isGlassAvailable
                    ? """
                        Показывает приложение целиком так, как оно выглядит на macOS до 26: \
                        матовые поверхности вместо стекла, а в окнах с боковым списком — \
                        список слева на системном фоне с разделителем вместо плавающей \
                        вставки.
                        """
                    : """
                        Переключать нечего: стекла нет в самой системе, и приложение уже \
                        показано обычным. Включить стекло там, где его нет, оно не может.
                        """
            )

            // Предупреждение стоит **до** нажатия, а не только в вопросе.
            //
            // Вопрос человек читает уже после того, как решил переключить, — и
            // читает его как формальность. Перезапуск здесь не формальность: он
            // снимает регистрацию на АТС, и если в этот момент ждут звонка,
            // переключать оформление не надо вовсе. Про это надо знать до того,
            // как тянешься к тумблеру.
            if isGlassAvailable {
                SettingsHint("""
                    Переключение перезапускает приложение: регистрация снимется и поднимется \
                    заново, а звонок в этот момент оборвётся.
                    """)
            }
        }

        BackgroundSection()

        // Свой раздел, а не строка рядом с темой. Язык не оформление: тема
        // решает, как приложение выглядит, а язык — на чём оно разговаривает,
        // и меняют его один раз при заведении рабочего места, а не по
        // настроению. Стоит после стекла, потому что перезапуска стоят обе
        // настройки, и о нём человек прочитает уже в соседней строке выше.
        SettingsSection("Язык", icon: "languages") {
            // Как и «Без стекла», выбор не применяется на месте: язык берётся
            // при запуске, и сменить его у открытых окон нельзя. Поэтому
            // переключатель показывает выбранное, а щелчок открывает вопрос —
            // и до ответа не меняется ничего.
            // Подпись у строки пустая: заголовок раздела уже сказал «Язык», и
            // повторять его строкой ниже незачем. Сама строка при этом
            // остаётся `SettingsRow` — она держит переключатель на той же
            // вертикали, что тема и тумблер выше.
            SettingsRow("") {
                Picker("", selection: Binding(
                    get: { LanguageSetting.current },
                    set: { pendingRestart = .language($0) }
                )) {
                    ForEach(LanguageSetting.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // Та же ширина, что у темы: два переключателя одного вида в
                // соседних разделах на разной ширине читаются как разные
                // элементы.
                .frame(maxWidth: 220, alignment: .leading)
            }

            // Меньше текста, как в Windows 1.0.4: последствия — одной строкой
            // со значком, подробности — в вопросе перед перезапуском.
            HStack(spacing: Theme.Metrics.elementSpacing) {
                LucideIcon(name: "rotate-cw", size: Theme.Icon.medium)
                Text("Требуется перезапуск")
                    .font(.footnote)
            }
            .compatForeground(Theme.Palette.textSecondary)
        }
        // Вопрос задаётся до правки, а не после: согласие здесь дают не на
        // оформление, а на перезапуск со снятием регистрации, и узнавать о нём
        // постфактум оператор не должен.
        //
        // Висит на последнем разделе, а обслуживает оба: диалог показывается
        // окну целиком, и место, к которому он привязан, на вид не влияет.
        .sheet(item: $pendingRestart) { pending in
            switch pending {
            case .chrome:
                restartDialog(
                    icon: "panels-top-left",
                    title: Text(model.settings.plainChrome ? "Вернуть стекло?" : "Выключить стекло?")
                ) { switchChrome() }

            case .language(let language):
                restartDialog(icon: "languages", title: Text("Сменить язык?")) {
                    switchLanguage(to: language)
                }
            }
        }
    }

    /// Вопрос перед перезапуском — один на оформление и язык.
    private func restartDialog(icon: String, title: Text, perform: @escaping () -> Void) -> some View {
        GraphiteDialog(
            icon: icon,
            title: title,
            message: Text("Приложение перезапустится, регистрация поднимется заново."),
            footnote: model.isInCall ? Text("Идущий разговор оборвётся.") : nil,
            actions: [
                .init(Text("Оставить как есть"), role: .cancel) { pendingRestart = nil },
                .init(Text("Перезапустить"), role: .primary) {
                    pendingRestart = nil
                    perform()
                },
            ]
        )
    }

    /// Переключить оформление: правка и перезапуск.
    ///
    /// Записи на диск отдельным шагом здесь нет, и это не забытая строка:
    /// менеджерские настройки пишутся сразу, самой правкой (`persistSettings` в
    /// `AppModel`), — а в «Управлении» на её месте стояло «Сохранить», потому
    /// что там запись придержана черновиком. Порядок при этом важен тот же:
    /// перезапуск без записи вернул бы приложение к прежнему оформлению — и без
    /// правки, ради которой его затевали.
    private func switchChrome() {
        model.settings.plainChrome.toggle()
        NSApp.sendAction(#selector(AppDelegate.relaunchApplication(_:)), to: nil, from: nil)
    }

    /// Сменить язык: запомнить выбор и перезапуститься.
    ///
    /// Порядок тот же и по той же причине, что у оформления: новый процесс
    /// поднимается раньше, чем завершается старый, и выбор он должен застать
    /// уже записанным. Запись синхронна — см. `LanguageSetting.apply()`.
    private func switchLanguage(to language: LanguageSetting) {
        // В журнал, а не молча: язык меняет то, как выглядит всё приложение, и
        // разбирая потом «у меня всё по-английски», начинают с журнала.
        model.append(level: .info, message: "язык интерфейса переключён на «\(language.rawValue)»")
        language.apply()
        NSApp.sendAction(#selector(AppDelegate.relaunchApplication(_:)), to: nil, from: nil)
    }
}

/// «Фон»: свои обои под окнами — с Windows-клиентом 1.0.4.
///
/// Меньше текста, больше видимого: миниатюра вместо описания, ползунки вместо
/// пояснений — результат виден в самой панели сразу.
private struct BackgroundSection: View {

    @EnvironmentObject private var model: AppModel
    @State private var failure: String?

    private var background: Binding<BackgroundSettings> {
        Binding(get: { model.settings.background }, set: { model.settings.background = $0 })
    }

    var body: some View {
        SettingsSection("Фон", icon: "image") {
            SettingsRow("") {
                HStack(spacing: Theme.Metrics.sectionSpacing) {
                    preview
                    VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
                        Button(action: choose) {
                            HStack(spacing: Theme.Metrics.tightSpacing) {
                                LucideIcon(name: "image", size: Theme.Icon.medium)
                                Text("Выбрать картинку…")
                            }
                        }
                        if model.settings.background.isEnabled {
                            Button(action: reset) {
                                HStack(spacing: Theme.Metrics.tightSpacing) {
                                    LucideIcon(name: "undo-2", size: Theme.Icon.medium)
                                    Text("Без обоев")
                                }
                            }
                        }
                    }
                }
            }

            if let failure {
                SettingsNote(verbatim: failure, isAlarming: true)
            }

            if model.settings.background.isEnabled {
                slider("Масштаб", value: \.scale, range: BackgroundSettings.scaleRange, unit: "%")
                slider("Размытие", value: \.blur, range: BackgroundSettings.blurRange, unit: "pt")
                slider("Яркость", value: \.brightness, range: BackgroundSettings.brightnessRange, unit: "%")

                SettingsRow("Прозрачность") {
                    Picker("", selection: background.transparency) {
                        Text("Нет").tag(BackgroundSettings.Transparency.off)
                        Text("Слабая").tag(BackgroundSettings.Transparency.light)
                        Text("Средняя").tag(BackgroundSettings.Transparency.medium)
                        Text("Сильная").tag(BackgroundSettings.Transparency.strong)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    /// Миниатюра того, что сейчас под окном.
    private var preview: some View {
        ZStack {
            if model.settings.background.isEnabled {
                WallpaperLayer(settings: model.settings.background)
            } else {
                Color(Graphite.windowBackground)
                LucideIcon(name: "image", size: 18)
                    .compatForeground(Theme.Palette.textTertiary)
            }
        }
        .frame(width: 96, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .compatOverlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private func slider(
        _ title: LocalizedStringKey,
        value key: WritableKeyPath<BackgroundSettings, Int>,
        range: ClosedRange<Int>,
        unit: String
    ) -> some View {
        SettingsRow(title) {
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(model.settings.background[keyPath: key]) },
                        set: { model.settings.background[keyPath: key] = Int($0.rounded()) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                )
                Text(verbatim: "\(model.settings.background[keyPath: key]) \(unit)")
                    .compatMonospacedDigit()
                    .compatForeground(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "heic", "tiff", "bmp", "gif", "webp"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Wallpaper.importImage(from: url)
            failure = nil
            model.settings.background.isEnabled = true
            // Новая картинка — пересчёт кэша; правка поля заставит панель
            // перерисоваться, даже если обои уже были включены.
            model.settings.background.scale = model.settings.background.scale
            model.append(level: .info, message: "оформление: выбраны обои")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func reset() {
        Wallpaper.remove()
        model.settings.background.isEnabled = false
    }
}
