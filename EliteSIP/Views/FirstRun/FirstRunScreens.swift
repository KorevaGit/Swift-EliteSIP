import AppKit
import SIPCore
import SwiftUI

/// Общая шапка экрана мастера: заголовок и пояснение под ним.
///
/// Своим кирпичом, а не пятью копиями: экраны мастера идут подряд, и заголовок,
/// стоящий на разной высоте, читается как дёрганье вёрстки — ровно то, чего рама
/// фиксированного размера и добивалась.
private struct FirstRunHeader: View {

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            Text(title)
                .font(Theme.Text.firstRunTitle)
            Text(subtitle)
                .font(.callout)
                .compatForeground(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Обёртка содержимого экрана: одинаковые отступы у всех пяти.
private struct FirstRunBody<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            content
        }
        .padding(.horizontal, Theme.Metrics.contentPadding * 2)
        .padding(.top, Theme.Metrics.contentPadding * 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 1. Приветствие и язык

/// Первый экран: приветствие и выбор языка.
///
/// Язык здесь не случайно: всё показанное дальше читается на выбранном. До
/// этапа 8 этого экрана быть не могло — в приложении был один язык, и выбор был
/// бы переключателем на ничто.
///
/// Применяется он **не сразу**: язык берётся при старте процесса
/// (`AppleLanguages`), и до перезапуска мастер идёт на том, что система угадала.
/// Перезапуск один и стоит перед финалом — там человек и увидит выбранный язык.
/// Цена принята сознательно: этот экран читает техподдержка, а язык выбирается
/// для того, кто будет работать за машиной потом.
struct FirstRunWelcomeScreen: View {

    @ObservedObject var flow: FirstRunFlow

    var body: some View {
        FirstRunBody {
            FirstRunHeader(
                title: "Добро пожаловать в EliteSIP",
                subtitle: "Рабочее место настраивается один раз. Займёт минуту."
            )

            Picker("", selection: $flow.language) {
                ForEach(LanguageSetting.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 260, alignment: .leading)

            Text("Язык интерфейса. Применится, когда настройка закончится.")
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
        }
    }
}

// MARK: - 2. Первый пользователь

/// Второй экран: кто будет работать за этой машиной.
///
/// **Экран для техподдержки, а не для сотрудника.** Он закрыт административным
/// пропуском, и это решение заказчика от 15 августа 2026: менеджеру нельзя дать
/// завести себя самому, иначе он вписывает чужой добавочный и снимает чужие
/// раздачи. После мастера дыра не открывается — добавочный правится только в
/// «Управлении», за тем же паролем.
struct FirstRunUserScreen: View {

    @ObservedObject var flow: FirstRunFlow

    var body: some View {
        FirstRunBody {
            FirstRunHeader(
                title: "Первый пользователь",
                subtitle: "Добавочный, пароль от него и то, как настроено рабочее место."
            )

            route

            switch flow.route {
            case .preset:
                credentials
                sitePicker
            case .manual:
                credentials
                hostField
            case .configFile:
                loadedSummary
            }

            Divider()

            pass
        }
    }

    // MARK: Ветка

    /// Выбор ветки — настоящими радиокнопками системы.
    ///
    /// `.radioGroup`, а не свои кружки из комплекта иконок: у трёх взаимно
    /// исключающих путей ровно этот системный вид, и рисовать его самому значило
    /// бы завести в комплекте две иконки, которых там нет, ради того, что macOS
    /// умеет сама.
    ///
    /// Предустановки внутри показываются только когда их больше одной. То же
    /// правило, что в «Аккаунте»: выбор из одного пункта — не выбор, а лишнее
    /// решение на экране, где их и так семь.
    /// Выбор файла — в сеттере привязки, а не в `onChange`.
    ///
    /// `onChange(of:perform:)` появился в macOS 11, а срез x86_64 живёт с
    /// Catalina. Тот же приём уже стоит в «Оформлении»: побочное действие
    /// принадлежит самому акту выбора, и в сеттере ему не хуже, чем в
    /// наблюдателе.
    private var routeBinding: Binding<FirstRunFlow.Route> {
        Binding(
            get: { flow.route },
            set: { value in
                flow.route = value
                if value == .configFile, flow.loadedConfig == nil { chooseConfig() }
            }
        )
    }

    private var route: some View {
        Picker("", selection: routeBinding) {
            if flow.showsPresetPicker {
                ForEach(flow.presets, id: \.name) { preset in
                    Text(verbatim: preset.name).tag(FirstRunFlow.Route.preset(name: preset.name))
                }
            } else if let single = flow.presets.first {
                Text(verbatim: single.name).tag(FirstRunFlow.Route.preset(name: single.name))
            }
            Text("Вручную").tag(FirstRunFlow.Route.manual)
            Text("Загрузить конфигурацию…").tag(FirstRunFlow.Route.configFile)
        }
        .labelsHidden()
        .pickerStyle(.radioGroup)
    }

    // MARK: Поля

    private var credentials: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            TextField("Добавочный", text: $flow.number)
                .frame(maxWidth: 110)
            SecureField("Пароль SIP", text: $flow.password)
                .frame(maxWidth: 150)
        }
    }

    private var hostField: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            TextField("Адрес АТС", text: $flow.host)
                .frame(maxWidth: 260)
            Text("Внешний адрес означает стук перед регистрацией, внутренний — нет.")
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
        }
    }

    /// Тумблер площадки — только у предустановки.
    ///
    /// Он решает две вещи разом: стучать ли перед регистрацией и какой из двух
    /// адресов пары уедет в профиль. В ручной ветке его нет вовсе — адрес там
    /// вписан руками, и спрашивать про площадку значило бы спрашивать дважды об
    /// одном и том же.
    private var sitePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            Picker("", selection: $flow.site) {
                Text("Офис").tag(SIPProfileSite.office)
                Text("Удалённо").tag(SIPProfileSite.remote)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 200, alignment: .leading)

            Text("Где стоит эта машина. От этого зависит адрес АТС и стук.")
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
        }
    }

    /// Что приехало из файла.
    ///
    /// Поля добавочного и пароля здесь спрятаны, но добавочный показан: иначе
    /// техподдержка молча заводит вторую регистрацию на чужой номер.
    private var loadedSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            if let config = flow.loadedConfig {
                Text(verbatim: flow.loadedConfigName)
                    .font(.callout)
                Text(
                    String(
                        format: NSLocalizedString(
                            "Добавочный %@, АТС %@.",
                            comment: "что приехало из файла конфигурации"
                        ),
                        config.profiles.active.account.username,
                        config.profiles.active.account.domain
                    )
                )
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
            } else {
                Text("Файл не выбран.")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)
            }
        }
    }

    private var pass: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            SecureField("Административный пароль", text: $flow.adminPassword)
                .frame(maxWidth: 260)
            Text("Настройку рабочего места заканчивает техподдержка.")
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
        }
    }

    // MARK: Файл

    /// `NSOpenPanel`, а не `fileImporter`: тот появился в macOS 11, а срез
    /// x86_64 живёт с Catalina. Тем же способом выбираются файл рингтона и
    /// настройки в «Обслуживании».
    private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = [EliteSIPDocument.fileExtension]
        panel.prompt = NSLocalizedString("Загрузить", comment: "кнопка в окне выбора файла")
        guard panel.runModal() == .OK, let url = panel.url else {
            // Отказ от выбора не должен оставлять ветку, в которой нечего
            // применить: «Далее» в ней погашена, и человек упирается в экран без
            // объяснения.
            flow.route = .manual
            return
        }

        do {
            let content = try EliteSIPDocument.read(try Data(contentsOf: url))
            switch content {
            case .config(let settings):
                flow.loadedConfig = settings
                flow.loadedConfigName = url.lastPathComponent
                flow.route = .configFile
                flow.notice = nil
            case .preset:
                // Предустановка — не конфигурация: в ней нет ни номера, ни
                // пароля, и заводить ею машину «как готовую» нельзя. Отдельным
                // отказом, а не молчанием: файлы лежат рядом и похожи.
                flow.notice = NSLocalizedString(
                    "Это предустановка, а не конфигурация: в ней нет добавочного и пароля.",
                    comment: "выбран файл предустановки вместо конфигурации"
                )
                flow.route = .manual
            }
        } catch let failure as EliteSIPDocument.Failure {
            flow.notice = failure.title
        } catch {
            flow.notice = EliteSIPDocument.Failure.damaged.title
        }
    }
}

// MARK: - 3. Тема

/// Третий экран: тема оформления.
///
/// Единственная из трёх настроек оформления, которая применяется живьём, — её и
/// видно сразу на самом окне мастера.
struct FirstRunAppearanceScreen: View {

    @ObservedObject var flow: FirstRunFlow

    var body: some View {
        FirstRunBody {
            FirstRunHeader(
                title: "Тема",
                subtitle: "Панель висит поверх CRM весь день — важно, чтобы она не била по глазам."
            )

            // Тема применяется сразу и к самому окну — выбор видно на себе, а
            // не обещанием. Побочное действие в сеттере, а не в `onChange`: тот
            // появился в macOS 11, а срез x86_64 живёт с Catalina.
            Picker(
                "",
                selection: Binding(
                    get: { flow.appearance },
                    set: { value in
                        flow.appearance = value
                        NSApp.appearance = value.appKitAppearance
                    }
                )
            ) {
                ForEach(AppearanceSetting.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 260, alignment: .leading)
        }
    }
}

// MARK: - 4. Стекло

/// Четвёртый экран: стекло или матовые поверхности.
///
/// Показывается только там, где стекло есть в системе (`Theme.Chrome.isGlassAvailable`) —
/// ниже macOS 26 выбирать не из чего, а погашенный тумблер на входе читается как
/// поломка ещё до того, как человек увидел приложение живым.
///
/// Живьём не применяется: корпус выбирается при сборке окон, и окно мастера уже
/// собрано. Поэтому выбор виден на следующем экране — после перезапуска.
struct FirstRunChromeScreen: View {

    @ObservedObject var flow: FirstRunFlow

    var body: some View {
        FirstRunBody {
            FirstRunHeader(
                title: "Оформление",
                subtitle: "Стекло или матовые поверхности, как на macOS до 26."
            )

            Toggle("Без стекла", isOn: $flow.plainChrome)
                .compatSwitchToggle()

            Text("Приложение закончит настройку и откроется заново — так выбор применится целиком.")
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 5. Финал

/// Пятый экран: всё готово.
///
/// Показывается уже после перезапуска, то есть на выбранном языке и в выбранном
/// корпусе — сам экран и служит доказательством, что выбор применился.
struct FirstRunFinaleScreen: View {

    var body: some View {
        FirstRunBody {
            FirstRunHeader(
                title: "Готово",
                subtitle: "Приятной работы. Телефон зарегистрирован и ждёт звонков."
            )

            Text("Приложение живёт в строке меню. Щелчок по значку открывает и убирает панель.")
                .font(.callout)
                .compatForeground(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
