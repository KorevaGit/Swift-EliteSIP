import Compat
import SIPCore
import SwiftUI

/// Панель софтфона.
///
/// Главное правило, из которого выведено всё остальное: **нижняя полоса
/// неподвижна**. Кнопка завершения обязана оказываться под курсором в одном и
/// том же месте независимо от того, появилась ли вторая линия, потеряна ли
/// регистрация, открыто ли поле перевода и сколько у сотрудника макросов.
/// Поэтому панель собрана в три яруса:
///
///   строка состояния → изменчивая середина → неподвижный низ
///
/// Середина заперта в рамку, которая не может отдать свою высоту содержимому, —
/// иначе стопка сообщала бы наверх идеальную высоту и утаскивала низ вниз.
///
/// Дайлпада здесь нет. Почти все звонки входящие и приходят в отдельное окно, а
/// номер для исходящего вводится с клавиатуры; освободившееся место занимает
/// сетка DTMF-макросов, ради которых панель и открывают в разговоре.
struct PhonePanelView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var incomingCall: IncomingCallPanel

    /// Тикает таймер разговора. Ровно раз в секунду и только пока панель на
    /// экране.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var now = Date()

    /// Вид, из-под которого раскрывается список профилей.
    @State private var anchor = MenuAnchor()

    /// Высота полосы заголовка — та, что сообщило окно.
    ///
    /// Умолчание нужно только на первый кадр, до того как окно ответит: 28 —
    /// величина полосы на macOS до 26. Ошибиться на ней не страшно, потому что
    /// ответ приходит в том же проходе раскладки.
    @State private var titleBarInset: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            statusBar

            // Середина занимает ровно то, что осталось, и ни точкой больше.
            // Высоту задаёт пустой прямоугольник, а содержимое кладётся
            // накладкой: накладка на размер родителя не влияет в принципе.
            Color.clear
                .frame(maxHeight: .infinity)
                .compatOverlay(alignment: .top) { middle }
                .clipped()

            bottomBar
                .padding(.top, Theme.Gap.macrosToAction)
        }
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.bottom, Theme.Metrics.contentPadding)
        .frame(width: Theme.Metrics.panelWidth)
        .frame(maxHeight: .infinity)
        // Окно прямоугольное, поэтому и подкраска без скругления: своего
        // скругления у содержимого быть не должно, иначе по углам проступят
        // углы окна.
        .themedPanelSurface(cornerRadius: 0)
        .compatIgnoreSafeArea()
        .onReceive(clock) { now = $0 }
        .compatBackground {
            WindowAccessor { window in
                // Полоса заголовка появилась, но таскать за фон всё равно
                // удобнее: панель узкая, и целиться в 28 точек сверху ради
                // передвижения — лишняя работа.
                window.isMovableByWindowBackground = true
                window.styleMask.remove(.resizable)
            }
        }
        .compatBackground {
            TitleBarInsetReader { titleBarInset = $0 }
        }
        // Поверх чужих окон — только в разговоре: там до «Завершить» тянутся не
        // глядя. В покое панель такое же окно, как остальные.
        .compatBackground { WindowLevel(level: model.isInCall ? .floating : .normal) }
        // Высота — вместе с полосой заголовка: при `.fullSizeContentView`
        // содержимое и рамка окна это одно и то же.
        .compatBackground { PanelHeight(height: panelHeight) }
        .onAppear {
            #if DEBUG
            // Позволяет проверить плавающую панель без ручного клика:
            // `EliteSIP.app/Contents/MacOS/EliteSIP --demo-incoming`.
            if ProcessInfo.processInfo.arguments.contains("--demo-incoming") {
                showIncomingCallDemo()
            }
            // Позволяет проверить регистрацию в собранном приложении без
            // ручного клика — например снимком экрана из скрипта.
            if ProcessInfo.processInfo.arguments.contains("--connect-on-launch") {
                Task { await model.connect() }
            }

            // Открывает настройки сразу: снимок этого окна нужен для сверки
            // раскладки и контраста, а дотянуться до него скриптом иначе
            // нечем — ⌘, до приложения не доходит, пока оно не в фокусе.
            if ProcessInfo.processInfo.arguments.contains("--open-settings") {
                NSApp.sendAction(#selector(AppDelegate.showSettingsWindow(_:)), to: nil, from: nil)
            }

            // Проверка звука одной командой: подключиться и сразу позвонить.
            // Автоматизировать «слышно себя» нельзя, а вот дойти до разговора
            // без десятка кликов — можно.
            //   EliteSIP.app/Contents/MacOS/EliteSIP --call-on-launch 600
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--call-on-launch"),
               index + 1 < ProcessInfo.processInfo.arguments.count {
                let number = ProcessInfo.processInfo.arguments[index + 1]
                Task {
                    await model.connect()
                    _ = await waitForRegistration()
                    model.dialedNumber = number
                    await model.placeCall()
                }
            }
            #endif
        }
    }

    /// Высота панели складывается из тех же промежутков, что и компоновка, а не
    /// подбирается на глаз. Все слагаемые постоянны, поэтому и остаток, который
    /// достаётся сетке макросов, постоянен: клавиши стоят на одном месте в любом
    /// состоянии.
    ///
    /// Зависимость от числа макросов — это константа установки, а не состояния:
    /// у сотрудника их шесть или девять, и меняются они в настройках, а не по
    /// ходу разговора.
    private var panelHeight: CGFloat {
        // Полоса заголовка входит в высоту: содержимое лежит под ней целиком, и
        // её место занимает отступ строки состояния. Число не наше — его
        // сообщило окно.
        let fixed = titleBarInset
            + Theme.Gap.titleToStatus
            + Theme.Metrics.statusBarHeight
            + Theme.Gap.statusToHeader
            + Theme.Metrics.headerHeight
            + Theme.Gap.headerToControls
            + Theme.Metrics.controlHeight
            + Theme.Gap.macrosToAction
            + Theme.Metrics.actionHeight
            + Theme.Metrics.contentPadding

        // Пустого места под макросы не резервируется: пока их нет, панель
        // ровно на них короче, а каждый добавленный ряд просто добавляет
        // высоты. Ряд управления при этом остаётся — он не про макросы.
        let rows = (model.usableMacros.count + Theme.Metrics.macroColumns - 1) / Theme.Metrics.macroColumns
        guard rows > 0 else { return fixed }

        let grid = CGFloat(rows) * Theme.Metrics.macroMinHeight
            + CGFloat(rows - 1) * Theme.Metrics.elementSpacing

        return fixed + Theme.Gap.controlsToMacros + grid
    }

    // MARK: - Ярус 1: голова

    /// Место под полосу заголовка.
    ///
    /// Пусто, и это правка от 6 августа 2026: раньше здесь стояла своя надпись
    /// «EliteSIP», а системную никто не отключал — `titleVisibility` осталась
    /// видимой, и два одинаковых названия лежали друг на друге со сдвигом.
    ///
    /// Теперь название рисует окно, а вёрстка только держит под него высоту:
    /// содержимое идёт под полосой целиком (`.fullSizeContentView`), и без
    /// этого места строка состояния уехала бы под светофор.
    private var titleBar: some View {
        Color.clear.frame(height: titleBarInset)
    }

    /// Капсула профиля, слот беды и вход в настройки.
    ///
    /// Стоит под полосой заголовка, а не на одной линии со светофором. Раньше
    /// она делила линию с кнопками окна ради экономии 28 точек, и это стоило
    /// двух вещей: у окна не было имени, а номер стоял так близко к светофору,
    /// что читался как четвёртая кнопка.
    ///
    /// Три слота с жёсткими ролями: капсула слева, шестерёнка справа, беда
    /// между ними. Средний тянется и обрезается, крайние не меняют размер
    /// никогда — иначе капсула ездила бы влево-вправо от длины чужой надписи, и
    /// попасть в неё с одного движения стало бы нельзя.
    private var statusBar: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            // Капсула получает свой размер первой: иначе жадный средний слот
            // забирает всю ширину, и пометка профиля обрезается даже когда
            // строка пустая и место есть.
            profilePicker
                .layoutPriority(1)

            // Тот же приём, что и у середины панели: место занимает пустой
            // прямоугольник, а надпись кладётся накладкой и на размер не влияет
            // вовсе.
            //
            // `minWidth` — то, что капсуле забирать нельзя. Иначе длинная
            // пометка съедала бы слот беды целиком, а беда важнее пометки:
            // пометку оператор и так знает, он сам за этой машиной сидит.
            Color.clear
                .frame(
                    minWidth: Theme.Metrics.troubleSlotMinWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .compatOverlay(alignment: .leading) { troubleLabel }
                .clipped()

            iconButton("gearshape", label: "Настройки") {
                NSApp.sendAction(#selector(AppDelegate.showSettingsWindow(_:)), to: nil, from: nil)
            }
        }
        .frame(height: Theme.Metrics.statusBarHeight)
        // Место под полосу заголовка занимает `titleBar` сверху, здесь остаётся
        // только воздух до неё.
        .padding(.top, Theme.Gap.titleToStatus)
    }

    /// Кнопка выбора профиля: точка состояния, номер, шеврон.
    ///
    /// Состояние и профиль в одном контроле намеренно. Это один вопрос, а не
    /// два — «кто я и на линии ли я», — и разводить его по разным углам панели
    /// значит заставлять глаз собирать ответ из двух мест.
    ///
    /// В разговоре капсула не нажимается: смена профиля и отключение снимают
    /// регистрацию и закрывают диалоги (M6b). Гаснет при этом только шеврон —
    /// номер и точка остаются в полную силу, потому что читать их надо и в
    /// разговоре.
    private var profilePicker: some View {
        Button {
            anchor.popUp(menu: makeProfileMenu())
        } label: {
            HStack(spacing: Theme.Metrics.tightSpacing) {
                Circle()
                    .fill(model.isOfflineByChoice ? Theme.Palette.offline : statusColor)
                    .frame(
                        width: Theme.Metrics.statusDotDiameter,
                        height: Theme.Metrics.statusDotDiameter
                    )

                Text(model.panelStatusTitle)
                    .font(Theme.Text.statusNumber)
                    .lineLimit(1)

                if let label = model.panelStatusLabel {
                    Text(label)
                        .font(Theme.Text.statusDetail)
                        .compatForeground(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Уступает место всему остальному: номер и шеврон
                        // обязаны остаться целыми, пометка — нет.
                        .layoutPriority(-1)
                }

                if model.canOpenProfileMenu {
                    // Шеврон — единственное, чем капсула сообщает, что она
                    // кнопка со списком, а не подпись. Иконки в комплекте нет,
                    // и рисовать её незачем: `ChevronDown` — форма.
                    ChevronDown()
                        .compatForeground(Theme.Palette.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Metrics.sectionSpacing)
            .frame(height: Theme.Metrics.profilePickerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedControlSurface(cornerRadius: pickerRadius)
        .hoverHighlight(cornerRadius: pickerRadius, isEnabled: model.canOpenProfileMenu)
        .disabled(!model.canOpenProfileMenu)
        .compatBackground { MenuAnchorView(anchor: anchor) }
        .compatAccessibilityLabel("Профиль \(model.panelStatusTitle)")
    }

    private var pickerRadius: CGFloat {
        Theme.Radius.capsule(height: Theme.Metrics.profilePickerHeight)
    }

    private func makeProfileMenu() -> NSMenu {
        let menu = NSMenu()

        for profile in model.profiles {
            let item = NSMenuItem(
                // Номер и пометка одной строкой: пометка — единственное, чем
                // два профиля одного добавочного различаются.
                title: model.profileMenuTitle(profile),
                action: nil,
                keyEquivalent: ""
            )
            item.state = (!model.isOfflineByChoice && profile.id == model.activeProfileID)
                ? .on
                : .off
            item.onSelect = { Task { await model.goOnline(profile: profile.id) } }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let offline = NSMenuItem(title: "Отключён", action: nil, keyEquivalent: "")
        offline.state = model.isOfflineByChoice ? .on : .off
        offline.onSelect = { Task { await model.goOffline() } }
        menu.addItem(offline)

        return menu
    }

    /// Слот беды между капсулой и шестерёнкой.
    ///
    /// Пустует почти весь день, и это правильно: место здесь занято не текстом,
    /// а его возможностью — появление надписи не должно ничего двигать.
    /// Обычное состояние сюда не пишется вовсе, его несёт цвет точки слева.
    @ViewBuilder
    private var troubleLabel: some View {
        if let trouble = model.trouble {
            if trouble.opensSettings {
                // Чинит человек — значит, надпись обязана вести туда, где чинят.
                // Ведёт в «Настройки», а оттуда в «Управление» по
                // административному паролю: и учётку, и пароль профиля заводит
                // администратор, а оператор пароля от добавочного не знает.
                Button {
                    NSApp.sendAction(#selector(AppDelegate.showSettingsWindow(_:)), to: nil, from: nil)
                } label: {
                    troubleContent(trouble)
                }
                .buttonStyle(.plain)
            } else {
                // Чинится само: сеть вернётся, сервер ответит. Нажимать не на
                // что, и делать вид, что есть, — обман.
                //
                // Подсказки с подробностями здесь тоже нет: на Catalina её не
                // существует, а вторая правда в двух местах хуже одной.
                // Подробности живут в журнале.
                troubleContent(trouble)
            }
        }
    }

    private func troubleContent(_ trouble: AppModel.Trouble) -> some View {
        HStack(spacing: Theme.Metrics.tightSpacing) {
            Text(trouble.text)
                .font(Theme.Text.statusDetail)
                .lineLimit(1)
                // Сжимается, но до предела: ниже 0.85 надпись перестаёт
                // читаться, и честнее обрезать хвост, чем показать нечитаемое.
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)

            if trouble.opensSettings {
                CompatSymbol(name: "exclamationmark.circle", size: Theme.Icon.small)
            }
        }
        .compatForeground(
            trouble.isFailure ? Theme.Palette.failure : Theme.Palette.textSecondary
        )
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch model.registration {
        case .idle: Theme.Palette.offline
        case .registering, .unregistering: Theme.Palette.connecting
        case .registered: Theme.Palette.registered
        case .failed: Theme.Palette.failure
        }
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            CompatSymbol(name: symbol, size: Theme.Icon.medium)
                .compatForeground(Theme.Palette.textSecondary)
                .frame(
                    width: Theme.Metrics.statusIconHitSize,
                    height: Theme.Metrics.statusIconHitSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 6)
        .compatAccessibilityLabel(label)
    }

    // MARK: - Ярус 2: изменчивая середина

    private var middle: some View {
        // Промежутки заданы поштучно, поэтому у стопки собственного шага нет.
        VStack(spacing: 0) {
            header
                .padding(.bottom, Theme.Gap.headerToControls)

            // Ряд управления виден и в покое, только выключенным. Прятать его
            // целиком значит менять геометрию панели ровно в момент ответа на
            // вызов: макросы и всё под ними подскакивали бы на его высоту.
            CallControls()

            // Поле перевода занимает место сетки макросов, а не встаёт под ней:
            // пока оператор набирает номер перевода, макросы всё равно не
            // нужны, а лишний ярус пришлось бы отнять у чего-то другого.
            if model.isTransferEntryVisible {
                // Единственная граница между управлением и тем, что под ним, —
                // воздух. Когда снизу пусто, нет и его.
                Color.clear.frame(height: Theme.Gap.controlsToMacros)
                TransferEntry()
                Spacer(minLength: 0)
            } else if !model.usableMacros.isEmpty {
                Color.clear.frame(height: Theme.Gap.controlsToMacros)
                MacroGrid()
            }
        }
        .padding(.top, Theme.Gap.statusToHeader)
    }

    /// Шапка: поле набора в покое, собеседник с таймером в разговоре, два поля
    /// при двух линиях. Высота у всех трёх одна и та же.
    @ViewBuilder
    private var header: some View {
        if model.lines.count > 1 {
            // Две линии — два поля вместо одного, в том же слоте.
            //
            // Отдельной полосы линий нет: линия и есть собеседник, и показывать
            // их порознь значит дважды писать одно и то же.
            VStack(spacing: Theme.Metrics.tightSpacing) {
                ForEach(model.lines.prefix(2)) { line in
                    LineField(line: line, now: now)
                }
            }
            .frame(height: Theme.Metrics.headerHeight)
        } else {
            CallHeader(now: now)
        }
    }

    // MARK: - Ярус 3: неподвижный низ

    /// Две кнопки, обе всегда на своём месте и в обоих видах панели.
    ///
    /// «История» стоит здесь, а не в полосе заголовка, потому что нужна
    /// постоянно: перезвонить по пропущенному — основной способ исходящего
    /// звонка. Её ширина задана жёстко, чтобы кнопка звонка не меняла размер.
    private var bottomBar: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            callButton

            Button {
                NSApp.sendAction(#selector(AppDelegate.showCallHistoryWindow(_:)), to: nil, from: nil)
            } label: {
                VStack(spacing: Theme.Metrics.hairSpacing) {
                    CompatSymbol(name: "clock", size: Theme.Icon.large)
                    Text("История")
                        .font(Theme.Text.actionCaption)
                }
                .frame(width: Theme.Metrics.historyWidth, height: Theme.Metrics.actionHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .themedControlSurface()
            .hoverHighlight()
            .compatAccessibilityLabel("История звонков")
        }
    }

    private var isCallButtonEnabled: Bool {
        model.isInCall || (model.canPlaceCall && model.hasDialedNumber)
    }

    private var callButton: some View {
        Button {
            Task {
                if model.isInCall {
                    await model.hangUp()
                } else {
                    await model.placeCall()
                }
            }
        } label: {
            CompatLabel(
                title: model.isInCall ? "Завершить" : "Позвонить",
                symbol: model.isInCall ? "phone.down.fill" : "phone.fill"
            )
            .font(Theme.Text.controlLabel)
            .compatForeground(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.actionHeight)
            .compatBackground(
                model.isInCall ? Theme.Palette.decline : Theme.Palette.answer,
                cornerRadius: Theme.Radius.control
            )
            .contentShape(Rectangle())
        }
        // Заливка задана явно, а не через .borderedProminent с tint: у того
        // радиус меньше макетного, а в неактивном окне акцент выцветает в
        // серый — панель висит поверх CRM и активной бывает редко.
        .buttonStyle(.plain)
        .hoverHighlight(isEnabled: isCallButtonEnabled)
        .disabled(!isCallButtonEnabled)
        // Системное затемнение выключенной кнопки на стеклянном фоне почти не
        // видно, и ярко-зелёная «Позвонить» выглядит рабочей, хотя ещё нет.
        .opacity(isCallButtonEnabled ? 1 : 0.4)
    }

    #if DEBUG
    /// Ждёт регистрации перед отладочным звонком: без неё Asterisk ответит 401
    /// и звонок не состоится.
    private func waitForRegistration(timeout: Interval = .seconds(15)) async -> Bool {
        let deadline = MonotonicClock.now + timeout
        while MonotonicClock.now < deadline {
            if model.isConnected { return true }
            try? await Task.sleep(.milliseconds(200))
        }
        return model.isConnected
    }
    #endif

    private func showIncomingCallDemo() {
        incomingCall.show(
            subject: IncomingCallSubject(
                callerNumber: "2929",
                callerName: "AutoDialer",
                queues: model.settings.queues
            ),
            policy: model.settings.incomingCall,
            onAnswer: {},
            onDecline: {}
        )
    }
}

/// Шапка одной линии: поле набора в покое, собеседник и таймер в разговоре.
///
/// Высота одна на оба состояния — внутри меняется только содержимое. Иначе при
/// ответе на вызов шапка вырастала бы и сдвигала вниз всё, что под ней.
struct CallHeader: View {

    @EnvironmentObject private var model: AppModel

    let now: Date

    var body: some View {
        content
            .frame(height: Theme.Metrics.headerHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .themedControlSurface()
    }

    @ViewBuilder
    private var content: some View {
        if model.isInCall {
            // Две строки: имя крупно, а номер, таймер и состояние — одной мелкой
            // строкой под ним.
            VStack(alignment: .leading, spacing: Theme.Metrics.hairSpacing) {
                Text(title)
                    .font(Theme.Text.callerName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: Theme.Metrics.tightSpacing) {
                    // Номер показывается только когда крупным идёт имя, иначе
                    // он повторил бы сам себя.
                    if hasName {
                        Text(model.activeLine?.peer ?? "")
                            .font(Theme.Text.callerNumber)
                            .compatForeground(Theme.Palette.textSecondary)
                            .lineLimit(1)
                            .layoutPriority(-1)

                        Text("·")
                            .font(Theme.Text.callerNumber)
                            .compatForeground(Theme.Palette.textTertiary)
                    }

                    if let duration {
                        Text(duration)
                            .font(Theme.Text.callTimer)
                            .compatMonospacedDigit()
                    }

                    Text(model.callStatus)
                        .font(Theme.Text.callerNumber)
                        .compatForeground(
                            model.isOnHold || model.isMicrophoneMuted
                                ? Theme.Palette.connecting
                                : Theme.Palette.textSecondary
                        )
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DialedNumberField()
        }
    }

    private var hasName: Bool {
        !(model.activeLine?.displayName ?? "").isEmpty
    }

    private var title: String {
        let line = model.activeLine
        let name = line?.displayName ?? ""
        return name.isEmpty ? (line?.peer ?? "") : name
    }

    private var duration: String? {
        guard let connectedAt = model.activeLine?.connectedAt else { return nil }
        let seconds = max(Int(now.timeIntervalSince(connectedAt)), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// Поле одной линии, когда линий две. Нажатие переводит звук на неё.
struct LineField: View {

    @EnvironmentObject private var model: AppModel

    let line: AppModel.CallLine
    let now: Date

    private var isActive: Bool { line.id == model.activeLineID }

    private var isSwitchable: Bool {
        !isActive && !model.isSwitchingLines && !model.isTransferring
    }

    var body: some View {
        Button {
            Task { await model.switchLine(to: line.id) }
        } label: {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                // Точка стоит в колонке шириной с точку капсулы, а не по своему
                // размеру: она мельче (6 против 8), и выровненные по краю
                // кружки разошлись бы центрами. Колонка выравнивает именно
                // центры — глаз считывает их, а не края.
                Circle()
                    .fill(isActive ? Theme.Palette.registered : Theme.Palette.textTertiary)
                    .frame(
                        width: Theme.Metrics.lineDotDiameter,
                        height: Theme.Metrics.lineDotDiameter
                    )
                    .frame(width: Theme.Metrics.statusDotDiameter)

                Text(line.displayName?.isEmpty == false ? line.displayName! : line.title)
                    .font(Theme.Text.lineTitle)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(status)
                    .font(Theme.Text.callerNumber)
                    .compatMonospacedDigit()
                    .compatForeground(isActive ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
            // Столько же, сколько внутри капсулы профиля: тогда обе точки
            // встают на одну вертикаль — в 20 точках от края окна.
            .padding(.horizontal, Theme.Metrics.sectionSpacing)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.lineFieldHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Звучащая линия выделена заливкой, ждущая приглушена: перепутать их
        // значит говорить в тишину.
        .compatBackground {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isActive ? 0.10 : 0.05))
        }
        .hoverHighlight(cornerRadius: 6, isEnabled: isSwitchable)
        .disabled(!isSwitchable)
    }

    private var status: String {
        guard let connectedAt = line.connectedAt else { return line.status }
        let seconds = max(Int(now.timeIntervalSince(connectedAt)), 0)
        let timer = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return line.isOnHold ? "\(timer) · удержание" : "\(timer) · разговор"
    }
}

/// Поле набора номера.
///
/// Настоящее текстовое поле, а не текст: дайлпада больше нет, номер вводится с
/// клавиатуры — значит поле обязано быть полем. Отсюда бесплатно берутся
/// backspace, выделение, ⌘C и ⌘V, которых в панели не было.
struct DialedNumberField: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            NumberField(
                text: Binding(
                    get: { model.dialedNumber },
                    set: { number in
                        // Правка руками выводит поле из истории: после неё оно
                        // уже не «пункт списка», и следующая стрелка вверх
                        // обязана начать сначала.
                        if number != model.dialedNumber { model.resetDialHistoryPosition() }
                        model.dialedNumber = number
                    }
                ),
                placeholder: "Номер",
                fontSize: Theme.Metrics.dialedNumberSize,
                isEnabled: model.canPlaceCall,
                onSubmit: { Task { await model.placeCall() } },
                onCancel: { model.clearDialedNumber() },
                onHistoryStep: { model.stepDialHistory($0) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            // Гаснет вместе с рядом управления и макросами: без регистрации
            // набирать некуда, и поле должно выглядеть так же, как остальное
            // недоступное, а не как единственное живое место в панели.
            .opacity(model.canPlaceCall ? 1 : Theme.Metrics.disabledOpacity)

            if model.hasDialedNumber {
                Button {
                    model.clearDialedNumber()
                } label: {
                    CompatSymbol(name: "xmark.circle.fill", size: Theme.Icon.medium)
                        .compatForeground(Theme.Palette.textTertiary)
                }
                .buttonStyle(.borderless)
                .compatAccessibilityLabel("Очистить номер")
            }
        }
    }
}

/// Кнопки, которые имеют смысл только в разговоре: удержание, микрофон, перевод.
///
/// Три, и только три: конференция и консультация делаются DTMF-макросами на
/// стороне сервера. Ряд виден и в покое, но выключенным — иначе его появление
/// сдвигало бы сетку макросов в момент ответа на вызов.
struct CallControls: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            controlButton(
                title: model.isOnHold ? "Вернуть" : "Удержать",
                symbol: model.isOnHold ? "play.fill" : "pause.fill",
                isOn: model.isOnHold,
                isEnabled: model.canHold
            ) {
                Task { await model.toggleHold() }
            }

            controlButton(
                title: "Микрофон",
                symbol: model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                isOn: model.isMicrophoneMuted,
                isEnabled: model.callPhase == .active
            ) {
                model.toggleMicrophone()
            }

            controlButton(
                title: "Перевести",
                symbol: "phone.arrow.right",
                isOn: model.isTransferEntryVisible,
                isEnabled: model.canTransfer && !model.isTransferEntryVisible
            ) {
                model.showTransferEntry()
            }
        }
        .frame(height: Theme.Metrics.controlHeight)
    }

    private func controlButton(
        title: String,
        symbol: String,
        isOn: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Metrics.tightSpacing) {
                CompatSymbol(name: symbol, size: Theme.Icon.small)
                Text(title)
                    .font(Theme.Text.statusDetail)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .compatForeground(isOn ? Color.white : Color.primary)
        .compatBackground {
            if isOn {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Palette.connecting)
            }
        }
        .themedControlSurface()
        .hoverHighlight(isEnabled: isEnabled)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : Theme.Metrics.disabledOpacity)
    }
}

/// Сетка DTMF-макросов на месте бывшего дайлпада.
///
/// Крупная подпись, три в ряд, порядок постоянный: оператор целится в место, а
/// не читает каждый раз. Вне разговора макросы видны, но выключены — набор у
/// сотрудника постоянный, и его раскладка должна запоминаться глазами до того,
/// как начнётся звонок.
struct MacroGrid: View {

    @EnvironmentObject private var model: AppModel

    private var rows: [[AppSettings.DTMFSettings.Macro]] {
        let macros = model.usableMacros
        return stride(from: 0, to: macros.count, by: Theme.Metrics.macroColumns).map { start in
            Array(macros[start..<min(start + Theme.Metrics.macroColumns, macros.count)])
        }
    }

    var body: some View {
        VStack(spacing: Theme.Metrics.elementSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Theme.Metrics.elementSpacing) {
                    ForEach(row) { macro in
                        macroButton(macro)
                    }
                    // Хвост неполного ряда: пустые места, чтобы кнопки не
                    // расползались по ширине и раскладка не менялась.
                    if row.count < Theme.Metrics.macroColumns {
                        ForEach(0..<(Theme.Metrics.macroColumns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func macroButton(_ macro: AppSettings.DTMFSettings.Macro) -> some View {
        Button {
            model.send(macro: macro)
        } label: {
            Text(macro.title)
                .font(Theme.Text.macro)
                // Подпись из одного слова переносить некуда: перенос разорвал бы
                // «Конференция» посреди слова, оставив висячую букву. Такие
                // подписи держим в строку и ужимаем кеглем, из двух слов —
                // переносим по пробелу.
                .lineLimit(macro.title.contains(" ") ? 2 : 1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                // Клавиша забирает свободную вертикаль и не сжимается ниже
                // минимума: иначе между сеткой и кнопкой завершения возник бы
                // провал вместо заданных 15 точек.
                .frame(minHeight: Theme.Metrics.macroMinHeight, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedControlSurface()
        .hoverHighlight(isEnabled: model.canSendDTMF)
        .disabled(!model.canSendDTMF)
        .opacity(model.canSendDTMF ? 1 : Theme.Metrics.disabledOpacity)
    }
}

/// Номер перевода и его подтверждение.
///
/// Собрано на тех же токенах, что и вся панель: системные `roundedBorder` и
/// `bordered` выпадали из окна другим радиусом, рамкой и высотой.
struct TransferEntry: View {

    @EnvironmentObject private var model: AppModel

    private func submit() {
        guard model.hasTransferNumber, !model.isTransferring else { return }
        Task { await model.blindTransfer() }
    }

    var body: some View {
        VStack(spacing: Theme.Metrics.elementSpacing) {
            CompatTextField(
                title: "Номер перевода",
                text: Binding(
                    get: { model.transferNumber },
                    set: { model.transferNumber = $0 }
                ),
                onSubmit: submit
            )
            .textFieldStyle(.plain)
            .font(Theme.Text.callerName)
            .lineLimit(1)
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .frame(height: Theme.Metrics.transferFieldHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedControlSurface()
            .disabled(model.isTransferring)

            HStack(spacing: Theme.Metrics.elementSpacing) {
                button("Отмена", isProminent: false) {
                    model.cancelTransferEntry()
                }
                .disabled(model.isTransferring)

                if model.isTransferring {
                    CompatSpinner()
                        .frame(height: Theme.Icon.medium)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.transferButtonHeight)
                } else {
                    button("Перевести", isProminent: true, action: submit)
                        .disabled(!model.hasTransferNumber)
                        .opacity(model.hasTransferNumber ? 1 : 0.4)
                }
            }
        }
    }

    private func button(
        _ title: String,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Text.controlLabel)
                .compatForeground(isProminent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Metrics.transferButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .compatBackground {
            if isProminent {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Palette.answer)
            }
        }
        .themedControlSurface()
        .hoverHighlight()
    }
}
