import SwiftUI

/// Панель софтфона — согласованная компоновка.
///
/// Главное правило, из которого выведено всё остальное: **нижняя полоса
/// неподвижна**. Кнопка завершения звонка обязана оказываться под курсором в
/// одном и том же месте независимо от того, появилась ли вторая линия, вылезла
/// ли полоса сбоя регистрации, открыто ли поле перевода и сколько у сотрудника
/// макросов. Поэтому панель собрана в три яруса:
///
///   шапка → изменчивая середина → неподвижный низ
///
/// Середина — единственное место, которому разрешено меняться, и она заперта в
/// прокрутку. Не ради прокрутки как таковой (в обычной работе её не видно), а
/// чтобы переполнение середины физически не могло сдвинуть низ вниз.
struct PanelView: View {

    @EnvironmentObject private var state: PrototypeState

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            // Середина занимает ровно то, что осталось, и ни точкой больше.
            //
            // Высоту задаёт пустой `Color.clear`, а содержимое кладётся
            // накладкой: накладка на размер родителя не влияет в принципе.
            // Обычная стопка так не умеет — она сообщает наверх свою идеальную
            // высоту, и при полосе сбоя со второй линией низ панели уезжал вниз
            // ровно так, как мы запретили.
            Color.clear
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if state.size == .full {
                        middle
                    } else {
                        callerOrNumber
                            .padding(.top, Tokens.Gap.statusToHeader)
                    }
                }
                .clipped()

            bottomBar
                .padding(.top, Tokens.Gap.macrosToAction)
        }
        .padding(.horizontal, Tokens.Space.wide)
        .padding(.bottom, Tokens.Space.wide)
        .frame(width: Tokens.Metrics.panelWidth, height: height)
        .protoSurface()
        .environment(\.colorScheme, state.isDark ? .dark : .light)
        .onReceive(timer) { _ in state.tick() }
    }

    /// Высота полного вида зависит от числа макросов — но это константа
    /// установки, а не состояния: у конкретного сотрудника макросов шесть или
    /// девять, и меняются они в настройках, а не по ходу разговора. Панель
    /// по-прежнему не дышит от того, что происходит на линии.
    private var height: CGFloat {
        guard state.size == .full else { return Tokens.Metrics.panelHeightCompact }
        let rows = (state.macros.count + Tokens.Metrics.macroColumns - 1) / Tokens.Metrics.macroColumns
        // Высота собрана из тех же промежутков, что и сама компоновка, а не
        // подобрана на глаз: полоса заголовка, шапка, УМП, промежуток, сетка в
        // минимальном размере, промежуток до низа и сам низ.
        let grid = CGFloat(rows) * Tokens.Metrics.macroMinHeight
            + CGFloat(rows - 1) * Tokens.Space.tight

        // Все слагаемые постоянны, поэтому и остаток, который достаётся сетке,
        // постоянен: клавиши стоят на одном месте в любом состоянии панели.
        let fixed = Tokens.Space.tight + Tokens.Metrics.statusBarHeight
            + Tokens.Gap.statusToHeader
            + Tokens.Metrics.headerHeight
            + Tokens.Gap.headerToControls
            + Tokens.Metrics.controlHeight
            + Tokens.Gap.controlsToMacros
            + Tokens.Gap.macrosToAction
            + Tokens.Metrics.actionHeight
            + Tokens.Space.wide                                        // нижнее поле окна

        return fixed + grid
    }

    // MARK: - Ярус 1: шапка

    /// Строка состояния: кто зарегистрирован, в каком состоянии клиент и вход в
    /// настройки.
    ///
    /// Она постоянная, а не всплывающая по сбою. Всплывающая полоса решала одну
    /// задачу — показать аварию, — но не отвечала на вопрос «под каким номером я
    /// сейчас работаю», а на трёх профилях это первое, что спрашивают. Заодно
    /// исчезает целый класс сдвигов: строка есть всегда и место занимает всегда.
    ///
    /// Собрана в один ярус с переключателем размера: отдельная полоса заголовка
    /// над ней стояла пустой и стоила ещё 24 точки.
    private var statusBar: some View {
        HStack(spacing: Tokens.Space.tight) {
            Circle()
                .fill(state.statusColor)
                .frame(width: 6, height: 6)

            Text(state.managerNumber)
                .font(Tokens.Text.statusNumber)
                .lineLimit(1)

            Text(state.statusText)
                .font(Tokens.Text.strip)
                .foregroundStyle(state.hasRegistrationFailure
                                 ? Tokens.Palette.failure
                                 : Tokens.Palette.textSecondary)
                .lineLimit(1)

            if state.hasRegistrationFailure {
                Button("Повторить") {}
                    .buttonStyle(.plain)
                    .font(Tokens.Text.strip)
                    .foregroundStyle(Tokens.Palette.warning)
            }

            Spacer(minLength: 4)

            iconButton("gearshape", help: "Настройки") {}

            iconButton(
                state.size == .full ? "chevron.up" : "chevron.down",
                help: state.size == .full ? "Свернуть панель" : "Развернуть панель"
            ) {
                state.size = state.size == .full ? .compact : .full
            }
        }
        .frame(height: Tokens.Metrics.statusBarHeight)
        .padding(.top, Tokens.Space.tight)
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .frame(width: 20, height: Tokens.Metrics.statusBarHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .protoHover(radius: 5)
        .help(help)
    }

    // MARK: - Ярус 2: изменчивая середина

    private var middle: some View {
        // Промежутки заданы поштучно, поэтому у стопки собственного шага нет.
        VStack(spacing: 0) {
            callerOrNumber
                .padding(.bottom, Tokens.Gap.headerToControls)

            // Ряд управления виден и в покое, только выключенным.
            //
            // Прятать его целиком, как сейчас в приложении, значит менять
            // геометрию панели ровно в момент ответа на вызов: макросы и всё
            // под ними подскакивали бы на высоту ряда. Выключенный ряд стоит те
            // же 30 точек и в покое, и в разговоре.
            callControls

            // Единственная граница между УМП и макросами — воздух. Линии здесь
            // нет, и ничего в этот промежуток больше не въезжает.
            Color.clear.frame(height: Tokens.Gap.controlsToMacros)

            // Поле перевода занимает место сетки макросов, а не встаёт под ней:
            // пока оператор набирает номер перевода, макросы всё равно не
            // нужны, а лишний ярус пришлось бы отнять у чего-то другого.
            if state.isTransferVisible {
                transferEntry
                Spacer(minLength: 0)
            } else {
                macroGrid
            }
        }
        .padding(.top, Tokens.Gap.statusToHeader)
    }

    /// Шапка: поле набора в покое, собеседник с таймером в разговоре.
    ///
    /// Высота задана снаружи и одна на оба состояния — внутри меняется только
    /// содержимое. Раньше поле набора было на 16 точек ниже шапки звонка, и
    /// панель дёргалась ровно в момент ответа.
    @ViewBuilder
    private var callerOrNumber: some View {
        if state.isInCall, state.hasSecondLine {
            // Две линии — два поля вместо одного, в том же слоте.
            //
            // Отдельной полосы линий больше нет: линия и есть собеседник, и
            // показывать их порознь значит дважды писать одно и то же. Слот
            // прежней высоты делится на две строки по 22 точки, поэтому всё,
            // что ниже, снова не двигается.
            VStack(spacing: 4) {
                lineField(
                    title: state.callerName ?? state.callerNumber,
                    status: state.timerText + " · " + (state.isOnHold ? "удержание" : "разговор"),
                    isActive: true
                )
                lineField(
                    title: "Соколов А.",
                    status: "03:41 · удержание",
                    isActive: false
                )
            }
            .frame(height: Tokens.Metrics.headerHeight)
        } else {
            headerContent
                .frame(height: Tokens.Metrics.headerHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.Space.wide)
                .protoControlSurface(Tokens.Radius.control)
        }
    }

    /// Поле одной линии. Нажатие переводит звук на неё.
    private func lineField(title: String, status: String, isActive: Bool) -> some View {
        Button {} label: {
            HStack(spacing: Tokens.Space.tight) {
                Circle()
                    .fill(isActive ? Tokens.Palette.answer : Tokens.Palette.tertiary)
                    .frame(width: 6, height: 6)

                Text(title)
                    .font(Tokens.Text.lineTitle)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(status)
                    .font(Tokens.Text.callerNumber)
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Tokens.Palette.textSecondary : Tokens.Palette.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Tokens.Space.wide)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Звучащая линия выделена заливкой, ждущая — приглушена. Разница видна
        // с одного взгляда, потому что перепутать их значит говорить в тишину.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isActive ? 0.10 : 0.05))
        )
        .protoHover(radius: 6, isEnabled: !isActive)
        .help(isActive ? "Звук идёт по этой линии" : "Переключить звук на \(title)")
    }

    @ViewBuilder
    private var headerContent: some View {
        if state.isInCall {
            // Две строки вместо трёх: имя крупно, а номер, таймер и состояние
            // собраны в одну мелкую строку под ним. Так шапка укладывается в 48
            // точек вместо 78, не теряя ничего из того, что в ней было.
            VStack(alignment: .leading, spacing: Tokens.Space.hair) {
                Text(state.callerName?.isEmpty == false ? state.callerName! : state.callerNumber)
                    .font(Tokens.Text.name)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 5) {
                    // Номер показывается только когда крупным идёт имя, иначе
                    // он повторил бы сам себя.
                    if state.callerName?.isEmpty == false {
                        Text(state.callerNumber)
                            .font(Tokens.Text.callerNumber)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(1)
                            .layoutPriority(-1)

                        Text("·")
                            .font(Tokens.Text.callerNumber)
                            .foregroundStyle(Tokens.Palette.tertiary)
                    }

                    Text(state.timerText)
                        .font(Tokens.Text.timer)
                        .monospacedDigit()

                    Text(state.callStateText)
                        .font(Tokens.Text.callerNumber)
                        .foregroundStyle(state.isOnHold || state.isMuted
                                         ? Tokens.Palette.warning
                                         : Tokens.Palette.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: Tokens.Space.tight) {
                // Настоящее текстовое поле, а не `Text`. Дайлпада больше нет,
                // номер вводится с клавиатуры — значит поле обязано быть полем:
                // отсюда бесплатно берутся backspace, выделение, ⌘C и ⌘V,
                // которых сейчас в панели нет.
                TextField("Номер", text: $state.dialedNumber)
                    .textFieldStyle(.plain)
                    .font(Tokens.Text.number)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !state.dialedNumber.isEmpty {
                    Button {
                        state.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Tokens.Palette.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Очистить")
                }
            }
        }
    }

    /// Три кнопки, и только три: конференция и консультация делаются
    /// DTMF-макросами на стороне сервера и из панели ушли вместе со всем циклом
    /// «Соединить / Отбой» вокруг них.
    ///
    /// Ряд собран одной сплошной полосой с разделителями внутри, а не тремя
    /// отдельными плитками.
    ///
    /// Раньше он отличался от сетки макросов только размером, и глаз читал его
    /// как первый ряд той же сетки: одинаковая заливка, одинаковый радиус,
    /// одинаковые промежутки. Здесь другой класс элементов и выглядит иначе —
    /// сегменты одного контрола, подпись в строку, высота меньше, а между ним и
    /// макросами стоит явная линия.
    private var callControls: some View {
        HStack(spacing: Tokens.Space.tight) {
            controlSegment(
                title: state.isOnHold ? "Вернуть" : "Удержать",
                symbol: state.isOnHold ? "play.fill" : "pause.fill",
                isOn: state.isOnHold
            ) { state.isOnHold.toggle() }

            controlSegment(
                title: "Микрофон",
                symbol: state.isMuted ? "mic.slash.fill" : "mic.fill",
                isOn: state.isMuted
            ) { state.isMuted.toggle() }

            controlSegment(
                title: "Перевести",
                symbol: "arrow.uturn.right",
                isOn: state.isTransferVisible
            ) { state.isTransferVisible.toggle() }
        }
        .frame(height: Tokens.Metrics.controlHeight)
        .disabled(state.phase != .active)
        .opacity(state.phase == .active ? 1 : 0.35)
    }

    private func controlSegment(
        title: String,
        symbol: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                Text(title)
                    .font(Tokens.Text.strip)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(isOn ? Tokens.Palette.warning : Color.primary.opacity(0.08))
        )
        .protoHover()
    }

    /// Место бывшего дайлпада. Крупная подпись, три в ряд, порядок постоянный —
    /// оператор целится в место, а не читает каждый раз.
    ///
    /// Вне разговора макросы видны, но выключены: набор у сотрудника постоянный,
    /// и его раскладка должна запоминаться глазами до того, как начнётся звонок.
    private var macroGrid: some View {
        VStack(spacing: Tokens.Space.tight) {
            ForEach(macroRows.indices, id: \.self) { index in
                HStack(spacing: Tokens.Space.tight) {
                    ForEach(macroRows[index]) { macro in
                        macroButton(macro)
                    }
                    // Хвост неполного ряда: пустые места, чтобы кнопки не
                    // расползались по ширине и раскладка не менялась.
                    if macroRows[index].count < Tokens.Metrics.macroColumns {
                        ForEach(0..<(Tokens.Metrics.macroColumns - macroRows[index].count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var macroRows: [[PrototypeState.Macro]] {
        stride(from: 0, to: state.macros.count, by: Tokens.Metrics.macroColumns).map { start in
            Array(state.macros[start..<min(start + Tokens.Metrics.macroColumns, state.macros.count)])
        }
    }

    private func macroButton(_ macro: PrototypeState.Macro) -> some View {
        Button {} label: {
            Text(macro.title)
                .font(Tokens.Text.macro)
                // Подпись из одного слова переносить некуда: SwiftUI рвал бы
                // «Конференция» посреди слова, оставляя висячую «я». Такие
                // подписи держим в одну строку и ужимаем кеглем, а из двух слов
                // — переносим по пробелу, как и раньше.
                .lineLimit(macro.title.contains(" ") ? 2 : 1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                // Клавиша забирает всю свободную вертикаль и сжимается до 44,
                // когда над ней появляются полосы линий и сбоя связи. Потолка
                // нет: иначе между сеткой и кнопкой завершения снова возник бы
                // провал вместо заданных 10 точек.
                .frame(minHeight: Tokens.Metrics.macroMinHeight,
                       maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .protoControlSurface()
        .protoHover(isEnabled: state.phase == .active)
        .disabled(state.phase != .active)
        .opacity(state.phase == .active ? 1 : 0.35)
    }

    /// Поле перевода.
    ///
    /// Собрано на тех же токенах, что и вся панель: раньше здесь стояли
    /// системные `roundedBorder` и `bordered`, и блок выпадал из окна — другой
    /// радиус, другая толщина рамки, другая высота, чужая заливка.
    private var transferEntry: some View {
        VStack(spacing: Tokens.Space.tight) {
            TextField("Номер перевода", text: $state.transferNumber)
                .textFieldStyle(.plain)
                .font(Tokens.Text.name)
                .lineLimit(1)
                .padding(.horizontal, Tokens.Space.wide)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .protoControlSurface()

            HStack(spacing: Tokens.Space.tight) {
                transferButton("Отмена", isProminent: false) {
                    state.isTransferVisible = false
                }
                transferButton("Перевести", isProminent: true) {}
                    .disabled(state.transferNumber.isEmpty)
                    .opacity(state.transferNumber.isEmpty ? 0.4 : 1)
            }
        }
    }

    private func transferButton(
        _ title: String,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Text.control)
                .foregroundStyle(isProminent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(isProminent ? Tokens.Palette.answer : Color.primary.opacity(0.08))
        )
        .protoHover()
    }

    // MARK: - Ярус 3: неподвижный низ

    /// Две кнопки, обе всегда на своём месте и в обоих видах панели.
    ///
    /// «История» стоит здесь, а не в шапке, потому что нужна постоянно —
    /// перезвонить по пропущенному это основной способ исходящего звонка. Её
    /// ширина задана жёстко, чтобы кнопка звонка не меняла размер.
    private var bottomBar: some View {
        HStack(spacing: Tokens.Space.tight) {
            Button {
                if state.isInCall {
                    state.phase = .idle
                    state.callSeconds = 0
                    state.isOnHold = false
                    state.isMuted = false
                    state.isTransferVisible = false
                } else {
                    state.phase = .active
                }
            } label: {
                HStack(spacing: Tokens.Space.tight) {
                    Image(systemName: state.isInCall ? "phone.down.fill" : "phone.fill")
                        .font(.system(size: 12))
                    Text(state.isInCall ? "Завершить" : "Позвонить")
                        .font(Tokens.Text.control)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Metrics.actionHeight)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.control)
                        // Заливка задана явно, а не через `.borderedProminent`:
                        // у того в неактивном окне акцент выцветает в серый, а
                        // панель висит поверх CRM и активной бывает редко.
                        .fill(state.isInCall ? Tokens.Palette.decline : Tokens.Palette.answer)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .protoHover(isEnabled: isCallButtonEnabled)
            .disabled(!isCallButtonEnabled)
            .opacity(isCallButtonEnabled ? 1 : 0.4)

            Button {} label: {
                VStack(spacing: 1) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13))
                    Text("История")
                        .font(.system(size: 10))
                }
                .frame(width: Tokens.Metrics.historyWidth, height: Tokens.Metrics.actionHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .protoControlSurface()
            .protoHover()
            .help("История звонков")
        }
    }

    private var isCallButtonEnabled: Bool {
        state.isInCall || !state.dialedNumber.isEmpty
    }
}
