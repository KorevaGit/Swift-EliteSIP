import AppKit
import PanelLink
import SIPCore
import SwiftUI

/// Фирменный знак — настоящая иконка приложения, а не вторая её копия.
///
/// `NSApp.applicationIconImage` берёт ровно то, что человек видел в Finder минуту
/// назад: корона над клавиатурой. Нарисовать знак второй раз внутри вью значило
/// бы завести вторую истину о том, как выглядит приложение, — и однажды они
/// разъедутся.
private struct FirstRunLogo: View {

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: Theme.Metrics.firstRunLogoSize, height: Theme.Metrics.firstRunLogoSize)
            // Тень мягкая и вниз: иконка уже несёт свою рамку и скругление, и
            // сильная тень под ней читается как наклейка поверх окна.
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .compatAccessibilityHidden(true)
    }
}

/// Общая шапка экрана мастера: заголовок и пояснение под ним.
///
/// Своим кирпичом, а не пятью копиями: экраны мастера идут подряд, и заголовок,
/// стоящий на разной высоте, читается как дёрганье вёрстки — ровно то, чего рама
/// фиксированного размера и добивалась.
private struct FirstRunHeader: View {

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    /// Плакатные экраны центрируют текст, формы — нет.
    var isCentered = false

    /// Знак экрана.
    ///
    /// Не украшение: экраны сменяются сдвигом, все четыре одинаковой рамой, и
    /// без знака человек различает их только по заголовку, который читает уже
    /// после того, как понял, куда попал. Приветствие и финал знака не просят —
    /// у них своё, фирменная корона.
    var glyph: Glyph?

    /// Знаки экранов мастера. Один из комплекта, второй нарисован формой —
    /// подходящего в комплекте нет, а `eye.slash` читался бы как «скрыто».
    enum Glyph {
        case firstUser
        case appearance
    }

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: Theme.Metrics.tightSpacing) {
            if let glyph {
                glyphView(glyph)
                    .compatForeground(Theme.Palette.textSecondary)
                    .padding(.bottom, Theme.Metrics.tightSpacing)
                    .compatAccessibilityHidden(true)
            }
            Text(title)
                .font(isCentered ? Theme.Text.firstRunPoster : Theme.Text.firstRunTitle)
            Text(subtitle)
                .font(.callout)
                .compatForeground(Theme.Palette.textSecondary)
                .multilineTextAlignment(isCentered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: isCentered ? .center : .leading)
    }

    @ViewBuilder
    private func glyphView(_ glyph: Glyph) -> some View {
        switch glyph {
        case .firstUser:
            CompatSymbol(name: "person.badge.plus", size: Theme.Metrics.firstRunGlyphSize)
        case .appearance:
            AppearanceGlyph(size: Theme.Metrics.firstRunGlyphSize)
        }
    }
}

/// Обёртка содержимого экрана: одинаковые поля и центр у всех четырёх.
///
/// Видов было два — «плакат» по центру и «форма» от верха, — и второй отменён
/// 17 августа 2026: центрируется всё. Различие осталось внутри, там где ему и
/// место: строки центрирует только заголовок, а поля ввода стоят колонкой по
/// левому краю (`FirstRunColumn`). Поля разной длины на общей осевой линии не
/// стоят в колонку, и глаз ищет каждое заново.
private struct FirstRunBody<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: Theme.Metrics.sectionSpacing) {
            content
        }
        .padding(.horizontal, Theme.Metrics.firstRunPadding)
        // Поля сверху и снизу равные — и никакой отдельной зоны под светофор.
        //
        // Зона была, и из-за неё содержимое стояло ниже середины: она съедала
        // высоту сверху, центр области уезжал вниз, и верхнее поле выходило
        // заметно больше нижнего. Видно это только на живом окне; снимок
        // 17 августа 2026 показал. Светофору при этом ничего не нужно: у обоих
        // видов экрана содержимое начинается много ниже полосы заголовка, потому
        // что центрируется по вертикали.
        .padding(.vertical, Theme.Metrics.firstRunPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Колонка содержимого формы: центрирована в окне, выровнена внутри себя.
///
/// Ровно то, что просили 17 августа 2026: «центрируй контент». Центрируется
/// **колонка**, а не каждая строка в ней, — поля и подписи внутри остаются по
/// левому краю. Иначе поля разной длины сели бы на общую осевую линию, перестали
/// стоять в колонку, и глаз искал бы каждое заново.
private struct FirstRunColumn<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            content
        }
        .frame(width: Theme.Metrics.firstRunColumnWidth, alignment: .leading)
    }
}

// MARK: - 1. Приветствие и язык

/// Первый экран: приветствие и выбор языка.
///
/// Язык здесь не случайно: всё показанное дальше читается на выбранном. До
/// этапа 8 этого экрана быть не могло — в приложении был один язык, и выбор был
/// бы переключателем на ничто.
///
/// Применяется он **сразу, перезапуском** — решение 17 августа 2026. Язык
/// берётся при старте процесса (`AppleLanguages`), и без перезапуска мастер
/// продолжался бы на том, что угадала система: человек выбрал English, а
/// следующий экран приезжал по-русски. Момент для перезапуска здесь идеальный и
/// единственный в мастере: кроме языка, на этом экране ещё ничего не введено, а
/// ни регистрации, ни разговора на первом запуске не существует.
///
/// Если язык не меняли, перезапуска не будет: мастер просто идёт дальше.
struct FirstRunWelcomeScreen: View {

    @ObservedObject var flow: FirstRunFlow

    var body: some View {
        FirstRunBody {
            FirstRunLogo()
                .padding(.bottom, Theme.Metrics.sectionSpacing)

            FirstRunHeader(
                title: "Добро пожаловать в EliteSIP",
                subtitle: "Рабочее место настраивается один раз. Займёт минуту.",
                isCentered: true
            )

            Picker("", selection: $flow.language) {
                ForEach(LanguageSetting.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .padding(.top, Theme.Metrics.sectionSpacing)

            Text("Язык интерфейса. Приложение откроется заново на выбранном.")
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
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

    /// Три уровня, а не одна таблица из трёх равных пунктов.
    ///
    /// Порядок согласован 17 августа 2026 и отражает, как часто этими путями
    /// пользуются, а не сколько их:
    ///
    /// 1. **Предустановка** — верхний уровень и обычный путь: типовое рабочее
    ///    место заводится так почти всегда.
    /// 2. **Вручную** — рядом, но ниже: машина, для которой шаблона нет.
    /// 3. **Загрузить конфигурацию** — внизу окна, отдельно от первых двух.
    ///    Это не «третий способ завести место», а перенос уже готового, и стоять
    ///    с ними в одном списке ему нельзя: одинаковый вид обещал бы, что выбор
    ///    равноценный, а он даже полей просит других.
    var body: some View {
        FirstRunBody {
            // Главный блок стоит по центру окна, а третий уровень — внизу.
            //
            // Двумя равными распорками, а не отступом: иначе блок съезжает вверх
            // ровно на высоту того, что прижато к низу, и «по центру» перестаёт
            // быть по центру — именно это и было видно 17 августа 2026.
            Spacer(minLength: 0)

            FirstRunHeader(
                title: "Первый пользователь",
                subtitle: "Кто будет работать за этой машиной.",
                isCentered: true,
                glyph: .firstUser
            )

            FirstRunColumn {
                if case .activationKey = flow.route {
                    keyEntry
                } else {
                    // Два ряда вместо четырёх строк: сверху — кто (добавочный и
                    // его пароль), под ним — где (рабочее место и площадка либо
                    // адрес). Порядок согласован 17 августа 2026 и читается как
                    // два вопроса, а не как шесть полей.
                    credentials

                    // Списка веток здесь больше нет: их осталось две, и вторая
                    // выбирается кнопкой внизу окна. Выпадающий список из
                    // одного пункта — не выбор, а недоразумение.
                    hostField
                }

                // Пропуск — только для путей, где номер вписывают руками.
                // Ключевой путь его не требует: административный пароль
                // приезжает в самом пакете, и требовать его у сотрудника,
                // который этого пароля не знает, значило бы закрыть основной
                // путь тем же замком, который он и открывает.
                if flow.route != .activationKey {
                    cautionAboutPass
                    pass
                }
            }

            Spacer(minLength: Theme.Metrics.sectionSpacing)

            configRow
        }
    }

    // MARK: Третий уровень — готовая конфигурация

    /// Внизу окна и подписью, а не пунктом списка.
    ///
    /// Кнопка без рамки: она не соперничает за внимание с первыми двумя
    /// уровнями, но и не спрятана — техподдержка, пришедшая переносить рабочее
    /// место, ищет её глазами первой и находит там, где кладут «прочее».
    private var configRow: some View {
        VStack(spacing: Theme.Metrics.hairSpacing) {
            switch flow.route {
            case .activationKey:
                // Ручной путь стоит внизу и без рамки не по невнимательности:
                // это не равноценный первому способ, а обходной — для машины,
                // до которой сервер не достаёт, — и обещать ему равный вид
                // нельзя.
                Button("Настроить эту машину вручную…") { flow.route = .manual }
                    .buttonStyle(.link)

            case .manual:
                // Обратная дорога: свернувший в ручную ветку по ошибке не
                // должен перезапускать мастер ради возврата к ключу.
                Button("Вернуться к ключу активации") { flow.route = .activationKey }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Ключ активации

    /// Основной путь с M9: сотрудник вводит ключ, остальное приезжает пакетом.
    @ViewBuilder
    private var keyEntry: some View {
        if let package = flow.openedPackage {
            openedSummary(package)
        } else {
            VStack(spacing: Theme.Metrics.elementSpacing) {
                // Моноширинный: ключ читают по знакам и сверяют с сообщением,
                // а пропорциональный шрифт делает «0» и «O» похожими ровно там,
                // где их и путают.
                TextField("Ключ из сообщения", text: keyBinding)
                    .font(.system(.body, design: .monospaced))
                    .disabled(flow.isOpeningKey)
                    // Отказ виден на самом поле, а не только словами.
                    //
                    // Рамка отвечает на «где ошибка», надпись под ней — на
                    // «какая». Порознь ни то ни другое не работает: голая
                    // надпись внизу окна не показывала, что перевводить, а
                    // голая рамка не говорила, ключ ли не тот или канал не
                    // ответил.
                    .compatOverlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .stroke(
                                flow.keyFailure == nil ? Color.clear : Theme.Palette.failure,
                                lineWidth: 1.5
                            )
                    }

                Button(flow.isOpeningKey ? "Проверяем…" : "Проверить ключ") {
                    Task { await flow.openKey() }
                }
                .disabled(flow.key.isEmpty || flow.isOpeningKey)

                // Отказ вытесняет подсказку, а не встаёт под ней: подсказка
                // «разделители не важны» уже прочитана к этому мгновению, а два
                // пояснения подряд под одним полем читаются как одно длинное.
                if let failure = flow.keyFailure {
                    Text(verbatim: failure)
                        .font(.footnote)
                        .compatForeground(Theme.Palette.failure)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Разделители и регистр не важны — вставьте ключ как есть.")
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Правка ключа гасит отказ: красная рамка над полем, которое человек уже
    /// перенабирает, обвиняет его в том, что он в это мгновение и исправляет.
    ///
    /// Побочное действие в сеттере, а не в `onChange`: тот появился в macOS 11,
    /// а срез x86_64 живёт с Catalina, — тем же способом здесь применяется тема.
    private var keyBinding: Binding<String> {
        Binding(
            get: { flow.key },
            set: { value in
                flow.key = value
                flow.keyFailure = nil
            }
        )
    }

    /// Что приехало в пакете — **до** того, как что-либо применится.
    ///
    /// Человек должен увидеть, чьё рабочее место поднимает, прежде чем машина
    /// зарегистрируется на АТС под чужим номером. Дешёвая защита от
    /// перепутанного ключа, и единственная, какая тут возможна.
    private func openedSummary(_ package: ActivationPackage) -> some View {
        VStack(spacing: Theme.Metrics.tightSpacing) {
            Text(verbatim: package.employee)
                .font(Theme.Text.firstRunTitle)

            Text(verbatim: "\(package.number) · \(package.preset.name)")
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)

            Text("Если это не вы — не продолжайте и сообщите в поддержку.")
                .font(.footnote)
                .compatForeground(Theme.Palette.caution)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Metrics.tightSpacing)

            Button("Ввести другой ключ") {
                flow.openedPackage = nil
                flow.keyFailure = nil
                flow.key = ""
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Поля

    // Все контролы экрана — по ширине колонки, и это не вкусовщина.
    //
    // Стояли они на четырёх разных ширинах — 110, 150, 200 и 260 точек, — и
    // правый край ступеньками сползал вниз: «некрасивая разметка», как это и
    // было названо. Одна ширина на всё даёт колонку, в которой глаз находит
    // следующее поле не глядя.
    private var credentials: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            TextField("Номер", text: $flow.number)
            SecureField("Пароль SIP", text: $flow.password)
        }
    }

    /// Жёлтая строка над пропуском — она же разделитель.
    ///
    /// Черта здесь стояла и была немой: она отделяла пропуск от полей, но не
    /// говорила, зачем он. Надпись делает и то и другое, поэтому черты больше нет
    /// (решение 17 августа 2026).
    ///
    /// Жёлтым, а не красным: незаполненный пропуск — не отказ, а незаконченный
    /// ввод. И жёлтым, а не серым: без него дальше не пройти, и узнавать об этом
    /// по погасшей кнопке «Далее» человек не должен.
    private var cautionAboutPass: some View {
        Text("Без административного пароля регистрацию не проверить.")
            .font(.footnote)
            .compatForeground(Theme.Palette.caution)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Metrics.tightSpacing)
    }

    private var pass: some View {
        SecureField("Административный пароль", text: $flow.adminPassword)
    }

    private var hostField: some View {
        TextField("Адрес АТС", text: $flow.host)
    }

}

// MARK: - 3. Оформление: тема и стекло

/// Третий экран: как приложение выглядит — тема и стекло вместе.
///
/// Экранов было два, и стали одним по решению 17 августа 2026. Делить их
/// заставляло только то, как настройки применяются: тема живьём, корпус — при
/// сборке окон. Человеку это различие не говорит ничего: он отвечает на один
/// вопрос, и два экрана подряд про внешний вид читались как заминка.
///
/// Тема применяется сразу и к самому окну мастера — выбор видно на себе. Стекло
/// не может: окно уже собрано, и его выбор виден после перезапуска, о котором
/// экран честно и предупреждает.
struct FirstRunAppearanceScreen: View {

    @ObservedObject var flow: FirstRunFlow

    // Плакат, а не форма.
    //
    // На экране заголовок, переключатель и тумблер: прижатые к верхнему левому
    // углу окна в 470 точек они оставляют под собой пустое поле — ровно то,
    // из-за чего переделывали приветствие.
    var body: some View {
        FirstRunBody {
            FirstRunHeader(
                title: "Оформление",
                subtitle: "Панель висит поверх CRM весь день — важно, чтобы она не била по глазам.",
                isCentered: true,
                glyph: .appearance
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
            .frame(maxWidth: 260)

            Divider()
                .frame(maxWidth: Theme.Metrics.firstRunColumnWidth)
                .padding(.vertical, Theme.Metrics.tightSpacing)

            // Стекло — двумя картинками, а не тумблером.
            //
            // Тумблер отвечал словами на вопрос, который словами не отвечается:
            // человек, впервые открывший приложение, не знает ни что такое
            // стекло в macOS 26, ни чем от него отличается матовая поверхность.
            //
            // Карточки показываются **всегда**, даже когда стекла в системе нет:
            // прежде экран прятал выбор целиком, и человек на Catalina не узнавал
            // ни того, что варианта два, ни того, почему у него один. Теперь
            // стеклянная карточка стоит на месте, погашенная, и подписана
            // причиной — «Требуется macOS 26».
            HStack(alignment: .top, spacing: Theme.Metrics.sectionSpacing) {
                // Отмечено то, что человек **увидит**, а не то, что стоит в
                // флаге. Разница вылезает на системах до macOS 26: `plainChrome`
                // там равен `false` («вручную на матовый не переводили»), но
                // приложение всё равно матовое — и отмеченной оказалась бы
                // погашенная стеклянная карточка.
                ChromePreviewCard(
                    isGlass: true,
                    isSelected: !flow.plainChrome && Theme.Chrome.isGlassAvailable,
                    isEnabled: Theme.Chrome.isGlassAvailable
                ) {
                    flow.plainChrome = false
                }

                ChromePreviewCard(
                    isGlass: false,
                    isSelected: flow.plainChrome || !Theme.Chrome.isGlassAvailable,
                    isEnabled: true
                ) {
                    // Там, где стекла нет, флаг не выставляется: он ничего не
                    // изменил бы, а перезапуск в конце мастера случился бы ради
                    // ничего — `completeFirstRun` считает его нужным по правке
                    // этого самого флага.
                    flow.plainChrome = Theme.Chrome.isGlassAvailable
                }
            }

            Text("Приложение откроется заново, чтобы применить оформление.")
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.Metrics.firstRunColumnWidth)
        }
    }
}

// MARK: - 4. Финал

/// Пятый экран: всё готово.
///
/// Показывается уже после перезапуска, то есть на выбранном языке и в выбранном
/// корпусе — сам экран и служит доказательством, что выбор применился.
struct FirstRunFinaleScreen: View {

    var body: some View {
        FirstRunBody {
            FirstRunLogo()
                .padding(.bottom, Theme.Metrics.sectionSpacing)

            FirstRunHeader(
                title: "Готово",
                subtitle: "Приятной работы. Телефон зарегистрирован и ждёт звонков.",
                isCentered: true
            )

            // Про Dock, а не про строку меню: с 17 августа 2026 приложение
            // остаётся в Dock всегда, и именно оттуда панель возвращают. Значок в
            // строке меню тоже есть, но обещать его единственной дорогой больше
            // нельзя — у кого строка меню забита, тот его не найдёт.
            Text("Приложение остаётся в доке. Щелчок по иконке возвращает панель.")
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Metrics.tightSpacing)
        }
    }
}
