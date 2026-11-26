import CallGuard
import PanelLink
import SwiftUI

/// Про что этот вызов — и, значит, что стоит на главном месте окна.
///
/// Три случая, а не запасная цепочка внутри одного. По боевым CDR на плечо
/// агента приходит CallerID очереди, а не клиента: клиентский лежит в
/// `accountcode` и в SIP не приезжает вовсе. То есть на раздаче номер одинаков
/// от вызова к вызову и не сообщает оператору ничего — а название кампании
/// сообщает, как здороваться. На обычном звонке всё наоборот: номер коллеги по
/// внутреннему или клиента — это и есть главное.
///
/// **Номер очереди в вызов не попадает — снято 27 августа 2026.** Живые
/// INVITE показали, что диалплан CallerID не подменяет: в `From` приезжает
/// номер клиента или добавочный переводящего, а не номер очереди. Поэтому
/// словарь «номер очереди → название» не сработал ни разу и в ноябре 2026
/// удалён. Прямой признак раздачи — `X-Autoanswer: TRUE`; запасной — форма
/// `From`.
///
/// Отличает раздачу от прямого звонка форма самого `From`, и различие чистое
/// на всех снятых вызовах:
///
/// ```
/// раздача:  From: "IT_Peleshko" <sip:79615362688@…>
/// раздача:  From: "MTS TestIT_Peleshko" <sip:79615362688@…>
/// клиент:   From: <sip:+79654756963@…>
/// ```
///
/// На раздаче очередь подставляет в имя название кампании, а номер оставляет
/// клиентский. Прямой внешний звонок приходит вообще без имени. Отсюда и
/// правило `campaign` ниже: имя есть, номер внешний — значит раздача, и номер
/// в ней принадлежит клиенту, то есть менеджеру не предназначен.
///
/// Называет раздачу имя из `From`: подпись по правилу из Spark, иначе само имя
/// в читаемом виде — см. `QueueTitles`. Так же в Windows и Linux.
enum IncomingCallSubject: Equatable {

    /// Раздача из очереди. Название сверху, номер под ним — всегда.
    ///
    /// Номер здесь принадлежит не клиенту, а **сотруднику колл-центра,
    /// переведшему лид**: раздача устроена переводом, и в CallerID переведённого
    /// вызова уходит добавочный переводящего (`CNUM 712` в CEL от 26 августа
    /// 2026). Менеджеру он нужен — это тот, к кому идти с вопросом по лиду.
    ///
    /// Поэтому номер не прячется, а проходит через `shown`: внутренний виден
    /// как есть, мобильный — под маской. Мобильный здесь означает, что очередь
    /// настроена не так, как боевые, и в вызов просочился номер клиента; маска
    /// закрывает этот случай, не мешая обычному.
    ///
    /// `masksMobile` — флаг маски, разобранный вместе с вызовом
    /// (`AppSettings.masksMobileNumbers`). Свойство вызова, а не глобальная
    /// настройка, которую каждый вид читает сам: так окно входящего, шапка
    /// панели и история не могут разойтись между собой.
    case queue(title: String, number: String, masksMobile: Bool)

    /// Звонок по сделке из CRM: менеджер нажал «Позвонить» в Битриксе, АТС
    /// сперва поднимает его самого и только потом набирает клиента.
    ///
    /// Отдельный случай, потому что новичка он сбивает: в окне видно вызов от
    /// собственного добавочного, и выглядит это как ошибка, а не как начало
    /// собственного звонка.
    ///
    /// Номер здесь не показывается ровно по той же причине, что и на раздаче:
    /// это свой добавочный, он одинаков от вызова к вызову и не сообщает
    /// ничего. Номера клиента у нас нет — в INVITE он не приезжает.
    case selfCall

    /// Обычный звонок: имя главным, номер под ним. Имени нет — номер главным.
    case caller(number: String, name: String?, masksMobile: Bool)

    /// Заголовок случая «звонок по сделке».
    ///
    /// Строкой в коде, а не настройкой: добавочный менеджера
    /// приложение и так знает из активного профиля. Требовать вписать его
    /// руками значило бы оставить случай выключенным на каждой установке, где
    /// про него забыли, и молча сломать его при смене добавочного.
    static let dealTitle = NSLocalizedString("Вызов по сделке", comment: "заголовок окна входящего по сделке")

    /// Кто этот вызов породил — нижней строкой в истории.
    ///
    /// Номера там нет и быть не может: наверху стоит слово, а сам номер — свой
    /// же добавочный, который прячет `hidesNumber`. Строка от этого оставалась
    /// пустой, а высоту всё равно занимала: справа под исходом стоит дата. Имя
    /// системы отвечает ровно на тот вопрос, на который номер и отвечал бы, —
    /// откуда звонок.
    ///
    /// В окне входящего этой подписи нет: там про источник говорит сам
    /// заголовок, а второй строкой окно молчит намеренно.
    // не переводится: имя продукта.
    static let dealSource = "Bitrix"

    /// Заголовок раздачи, пришедшей без имени.
    ///
    /// Общий и нейтральный: до ноября 2026 здесь стояло «Горячая раздача», и
    /// так подписывалась любая линия колл-центра. Раздачу с именем называет
    /// `QueueTitles.headline` — правилом из Spark или самим именем.
    static let distributionTitle = NSLocalizedString(
        "Входящий из колл-центра", comment: "заголовок окна входящего на раздаче без имени"
    )

    /// Разбор того, что пришло в INVITE.
    ///
    /// Одно место на все вызовы окна, включая проверочный показ из настроек:
    /// иначе проверка показывала бы не то, что увидит оператор на боевом
    /// вызове, — а ради этого её и открывают.
    ///
    /// Свой добавочный проверяется **раньше** признаков раздачи: вызов по
    /// сделке иначе назывался бы раздачей. Сравнение по цифрам — номер
    /// приходит из SIP, а в настройки его вписывает человек.
    ///
    /// - Parameter queueRules: подписи раздач из Spark (`settings.queues.rules`).
    init(
        callerNumber: String,
        callerName: String?,
        requestsAutoAnswer: Bool = false,
        ownNumber: String,
        queueRules: [QueueTitles.Rule] = [],
        masksMobileNumbers: Bool = true
    ) {
        let own = Self.digits(ownNumber)
        let caller = Self.digits(callerNumber)

        if !own.isEmpty, own == caller {
            self = .selfCall
        } else if requestsAutoAnswer || Self.campaign(number: caller, name: callerName) {
            // Просьба снять трубку самостоятельно — и есть признак раздачи.
            //
            // Прямой признак, а не догадка по форме `From`, и потому главный.
            // Боевая раздача приходит с внутреннего номера и с именем, то есть
            // выглядит ровно как звонок коллеги, и отличить их по номеру или
            // имени нельзя в принципе:
            //
            // ```
            // раздача:  "Call_Center"                   <716>  X-Autoanswer: TRUE
            // раздача:  "GORACHAYA RAZDACHACall Center"  <710>  X-Autoanswer: TRUE
            // коллега:  "Semenov_Artyom"                 <132>  — заголовка нет
            // ```
            //
            // Какая это линия, говорит имя: правило из Spark, иначе само имя
            // в читаемом виде. Имени нет — общий заголовок.
            let title = QueueTitles.headline(callerName, rules: queueRules) ?? Self.distributionTitle
            self = .queue(title: title, number: callerNumber, masksMobile: masksMobileNumbers)
        } else {
            self = .caller(number: callerNumber, name: callerName, masksMobile: masksMobileNumbers)
        }
    }

    /// Раздача ли это — для истории и журнала машины.
    var isDistribution: Bool {
        if case .queue = self { return true }
        return false
    }

    /// Только цифры и служебные знаки.
    ///
    /// Номер приходит из SIP по-разному: `+7…`, `8 (918)…`, просто `712`.
    /// Сравнивать их между собой можно только по цифрам.
    private static func digits(_ number: String) -> String {
        number.filter { $0.isNumber || $0 == "*" || $0 == "#" }
    }

    /// Сколько цифр делает номер внешним.
    ///
    /// Добавочные у заказчика трёхзначные, номера очередей — от двух
    /// до четырёх цифр. Семь — первый порог, за которым не остаётся ни одного
    /// внутреннего номера, и при этом он ниже любого городского.
    ///
    /// Порог нужен затем, чтобы правило не съело обычный звонок коллеги.
    /// «Иванов» с добавочного 172 — это имя и номер, оба полезные, и прятать
    /// 172 не от кого.
    private static let externalNumberLength = 7

    /// Название кампании, если этот вызов — раздача.
    ///
    /// Два условия, и оба обязательны. **Имя есть и это не сам номер** —
    /// прямой внешний звонок приходит либо без имени вовсе, либо с именем,
    /// повторяющим номер (так его кладёт в `P-Asserted-Identity` транк), и
    /// принимать такой повтор за название кампании значило бы прятать номер у
    /// всех подряд. **Номер внешний** — иначе под правило попал бы коллега с
    /// добавочного.
    ///
    /// - Parameter number: только цифры, уже нормализованные.
    /// - Returns: раздача ли это.
    private static func campaign(number: String, name: String?) -> Bool {
        guard let name else { return false }
        let title = name.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return false }
        guard digits(title) != number else { return false }
        return number.count >= externalNumberLength
    }

    /// Мобильный номер под маской: `+7` и звёздочки.
    ///
    /// Страховка на случай, когда номер клиента снова окажется там, где его
    /// быть не должно. Разбор раздачи (`campaign`) опирается на форму `From`, а
    /// форму эту задаёт чужой диалплан — 27 августа 2026 он уже менялся один
    /// раз, и менеджеры полдня видели мобильные лидов. Маска не зависит ни от
    /// какого разбора: мобильный не показывается целиком нигде и никогда,
    /// правильно ли распознан вызов или нет.
    ///
    /// Мобильный узнаётся по коду: одиннадцать цифр, страна `7` или `8`,
    /// следующая — `9`. Городские (`74952…`) под правило не попадают: их
    /// показывают в CRM открыто, и прятать их не от кого.
    ///
    /// Звёздочек ровно столько, сколько скрыто цифр, — маска не должна врать
    /// про длину номера.
    ///
    /// - Returns: маска или `nil`, если номер не мобильный.
    static func masked(_ number: String) -> String? {
        let digits = Self.digits(number)
        guard digits.count == 11 else { return nil }
        guard digits.first == "7" || digits.first == "8" else { return nil }
        guard digits.dropFirst().first == "9" else { return nil }
        return "+7" + String(repeating: "*", count: digits.count - 1)
    }

    /// Номер входящего в том виде, в каком его видит менеджер.
    ///
    /// Одна дверь на все три места, где номер показывается: окно входящего,
    /// шапка панели в разговоре и история. Три отдельных правила разошлись бы —
    /// это уже случилось однажды, когда окно номер прятало, а панель через
    /// секунду показывала его крупно.
    ///
    /// `masks: false` — отдел, которому номер клиента нужен открытым: номер
    /// показывается как пришёл.
    static func shown(number: String, masks: Bool) -> String {
        guard masks else { return number }
        return masked(number) ?? number
    }

    /// Номер этого вызова в том виде, в каком его видит менеджер, — с тем
    /// флагом маски, с которым вызов разобран.
    func shown(number: String) -> String {
        switch self {
        case .queue(_, _, let masks), .caller(_, _, let masks):
            return Self.shown(number: number, masks: masks)
        case .selfCall:
            return Self.shown(number: number, masks: true)
        }
    }

    /// Что стоит на главном месте — в окне входящего и в шапке панели.
    ///
    /// Свойство, а не третья `switch` по месту показа. Окно и панель — это два
    /// вида одного вызова, и разойтись они не имеют права.
    var headline: String {
        switch self {
        case .queue(let title, _, _): return title
        case .selfCall: return IncomingCallSubject.dealTitle
        case .caller(let number, let name, _):
            guard let name, !name.isEmpty else { return shown(number: number) }
            return name
        }
    }

    /// Номер мелкой строкой под заголовком. `nil` — показывать нечего.
    ///
    /// Прячет ли этот вызов номер собеседника целиком.
    ///
    /// Отдельно от `secondaryNumber`, хотя на раздаче молчат оба. Разница в
    /// вопросе. `secondaryNumber` отвечает «что поставить второй строкой», и
    /// на обычном звонке без имени он молчит просто потому, что номер уже
    /// стоит первой. Это — «показывать ли номер вообще», и в истории, где
    /// номер стоит внизу даже когда он же написан наверху, спрашивать надо
    /// именно так.
    var hidesNumber: Bool {
        switch self {
        case .selfCall: return true
        case .queue, .caller: return false
        }
    }

    /// Номер, который щелчок в окне входящего кладёт в буфер обмена. `nil` —
    /// копировать нечего.
    ///
    /// Копируется только то, что оператор и так видит. Номер под маской не
    /// копируется вовсе: маска — страховка от утечки лидов, и буфер обмена её
    /// не обходит. Звонок по сделке номера не показывает — его и не копируют.
    /// Правило то же, что у Windows и Linux (`CopyableNumber`).
    var copyableNumber: String? {
        let number: String
        switch self {
        case .selfCall: return nil
        case .queue(_, let value, _), .caller(let value, _, _): number = value
        }
        guard !hidesNumber, !number.isEmpty, shown(number: number) == number else { return nil }
        return number
    }

    /// Пусто на звонке по сделке: там номер — свой же добавочный, одинаковый
    /// от вызова к вызову, и сказать им нечего. Пусто и на обычном звонке без
    /// имени: номер уже стоит заголовком и повторил бы сам себя.
    var secondaryNumber: String? {
        switch self {
        case .selfCall: return nil
        case .queue(_, let number, _):
            guard !number.isEmpty else { return nil }
            return shown(number: number)
        case .caller(let number, let name, _):
            guard let name, !name.isEmpty, !number.isEmpty else { return nil }
            return shown(number: number)
        }
    }
}

/// Содержимое плавающего окна входящего вызова.
///
/// Два состояния из макета, и переключает их одна настройка. Обычное: зелёная
/// «Ответить» и красная «Отклонить» рядом. С подтверждением цифрой: ряд
/// нейтральных цифровых целей, а «Отклонить» уезжает под них отдельной строкой.
///
/// Цели именно нейтральные, а не зелёные, и это часть защиты, а не вкусовщина:
/// кликер по шаблону изображения ищет на экране цветное пятно кнопки. Когда
/// все четыре цели выглядят одинаково, искать нечего.
///
/// Порядок «ответить / отклонить» при этом не перемешивается: у этих действий
/// разные последствия, и провоцировать оператора на случайный отказ от лида
/// недопустимо.
///
/// Принять вызов можно только мышью и сразу: клавиатурного пути нет намеренно
/// (нажатие клавиши не оставляет защите ни одного признака живого человека), а
/// задержки активации нет по решению заказчика — её цену платил оператор на
/// каждом вызове. «Отклонить» доступен и с клавиатуры, и для screen reader.
///
/// Звонок по сделке (`IncomingCallSubject.selfCall`) меняет в окне ровно две
/// вещи: заголовок и подсказку над кнопками. Кнопки, их порядок, якорь,
/// рингтон и вся защита остаются прежними — раздачи лидов на таком вызове нет,
/// но и повода заводить второе поведение окна тоже нет.
struct IncomingCallView: View {

    let subject: IncomingCallSubject
    let challenge: CallGuardChallenge
    let isGuarded: Bool
    let onAttempt: @MainActor (Character) -> Void
    let onDecline: @MainActor () -> Void

    @EnvironmentObject private var panel: IncomingCallPanel

    /// Номер только что ушёл в буфер: подпись окна на время говорит об этом.
    @State private var isNumberCopied = false

    /// Номер последнего копирования. Подпись гасит только таймер последнего
    /// щелчка — иначе второй щелчок погас бы по таймеру первого.
    @State private var copyGeneration = 0

    /// Сколько подпись говорит «номер скопирован».
    private static let copiedNoticeTime: TimeInterval = 2

    var body: some View {
        // Промежутки заданы поимённо, а не общим spacing: ярусы здесь неравные
        // по смыслу — шапка и карточка отвечают на «что это за вызов» и стоят
        // близко, кнопки отделены, потому что это уже действие.
        //
        // Без Spacer и без заданной высоты: окно подгоняется под содержимое.
        // Растянутый по фиксированной высоте столбец оставлял пустую полосу
        // между именем звонящего и кнопками.
        VStack(alignment: .leading, spacing: 0) {
            // Шапка и карточка — ручка переноса окна. Кнопки — нет: нажатие
            // на них остаётся нажатием, и перенос не принимает вызов.
            //
            // У карточки ручка своя: щелчок без переноса копирует номер.
            // Отдельной кнопки нет — окно не должно расти ради неё, а имя и
            // номер и есть то, что хочется скопировать.
            VStack(alignment: .leading, spacing: 0) {
                header
                    .overlay(WindowDragHandle())
                caller
                    .overlay(copyHandle)
                    .padding(.top, Theme.Gap.incomingHeaderToCaller)
            }
            // Пометка встаёт на место кнопок, а не вместо них: высота окна не
            // дёргается, а нажать на погашенную кнопку уже нельзя.
            actions
                .opacity(panel.takenNotice == nil ? 1 : 0)
                .allowsHitTesting(panel.takenNotice == nil)
                .compatOverlay(alignment: .bottom) {
                    if let notice = panel.takenNotice {
                        // На графитовой плашке высотой с кнопки, золотистым,
                        // как статусы звонка: на обоях текст не читался.
                        Text(verbatim: notice)
                            .font(Theme.Text.controlLabel)
                            .compatForeground(Theme.Palette.connecting)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .padding(.horizontal, Theme.Metrics.contentPadding)
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metrics.incomingCallButtonHeight)
                            .graphiteSurface(.control)
                            .environment(\.graphiteSurfaceOpacity, 1)
                    }
                }
                .padding(.top, Theme.Gap.incomingCallerToActions)
        }
        .padding(Theme.Metrics.contentPadding)
        .frame(width: Theme.Metrics.incomingCallPanelWidth)
        .themedIncomingSurface()
    }

    /// Шапка: цветной якорь, подпись, щит.
    ///
    /// Причина отказа занимает место подписи «Входящий вызов». Одно место на
    /// оба сообщения и в обоих состояниях окна: отдельная строка под отказ
    /// дёргала бы высоту окна прямо под рукой оператора, а подпись в этот
    /// момент всё равно ничего не сообщает — что вызов входящий, он уже понял.
    private var header: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            anchor

            Text(panel.refusal ?? caption)
                .font(Theme.Text.incomingCaption)
                .compatForeground(panel.refusal == nil ? Color.secondary : Theme.Palette.decline)
                .animation(.easeOut(duration: 0.15), value: panel.refusal)

            Spacer(minLength: Theme.Metrics.sectionSpacing)

            // Щит — честный индикатор того, что защита работает. Когда её
            // выключили, значка нет, и это видно на скриншоте экрана.
            if isGuarded {
                CompatSymbol(name: "lock.shield.fill", size: Theme.Icon.medium)
                    .compatForeground(Theme.Palette.textTertiary)
                    .compatAccessibilityLabel("Защита от автокликеров включена")
            }
        }
    }

    /// Подпись шапки. «Номер скопирован» — на месте подписи, а не новой
    /// строкой, по той же причине, что и отказ.
    private var caption: String {
        if panel.takenNotice != nil {
            return NSLocalizedString("Вызов снят", comment: "подпись в окне входящего: вызов снят до ответа")
        }
        return isNumberCopied
            ? NSLocalizedString("Номер скопирован", comment: "подпись в окне входящего после копирования номера")
            : NSLocalizedString("Входящий вызов", comment: "подпись в окне входящего")
    }

    /// Ручка переноса над карточкой; номер скрыт или его нет — просто ручка.
    private var copyHandle: WindowDragHandle {
        guard let number = subject.copyableNumber else { return WindowDragHandle() }
        return WindowDragHandle(
            onClick: { copy(number) },
            toolTip: NSLocalizedString("Скопировать номер", comment: "подсказка над номером в окне входящего")
        )
    }

    /// Номер — в буфер обмена. Фокус окно при этом не берёт: оно
    /// неактивирующее, а буферу активность приложения не нужна.
    private func copy(_ number: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(number, forType: .string) else { return }

        isNumberCopied = true
        copyGeneration += 1
        let generation = copyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedNoticeTime) {
            guard generation == copyGeneration else { return }
            isNumberCopied = false
        }
    }

    /// Цветной якорь — то, чем окно набирает заметность.
    ///
    /// Оно встаёт в случайную точку поверх произвольной CRM, и найти его глазами
    /// оператор обязан за доли секунды. Плотностью фона это не решается: фон у
    /// окна стеклянный и тон берёт у того, что под ним.
    ///
    /// Цена названа прямо и записана в `docs/anti-autoclicker.md`: постоянный
    /// узнаваемый якорь обесценивает случайную позицию против кликера по
    /// шаблону изображения — тот находит якорь и жмёт по постоянному смещению.
    /// Принято потому, что позицией мы от шаблонного кликера и так не
    /// защищались: от него защищает цифровая цель. В обычном режиме на окне и
    /// так есть зелёная «Ответить», и якорь шаблону ничего нового не даёт; в
    /// цифровом принимающая цифра случайна, и клик по постоянному смещению
    /// попадает в цель в одном случае из четырёх.
    /// Фигура — та же, что в истории (`CallOutcomeBadge`), а не своя картинка
    /// из комплекта. Оператор видит эти два окна каждый день, и входящий вызов
    /// в них должен выглядеть одинаково: залитый кружок со стрелкой внутрь.
    /// Заодно стрелка рисуется путём и остаётся резкой на любом размере, а
    /// комплект иконок для Catalina от неё не растёт.
    ///
    /// Размер — иконочный (`Icon.large`), а не тот, что в истории. Там значок
    /// главный в строке и потому крупный, здесь он стоит рядом с подписью в
    /// 11 точек, и на двадцати двух возвышался над ней, как ярлык над текстом.
    /// Якорю хватает цвета: заметность даёт зелёное пятно, а не его площадь.
    private var anchor: some View {
        CallOutcomeBadge(
            isIncoming: true,
            isCompleted: true,
            color: panel.takenNotice == nil ? Theme.Palette.outcomeAnswered : Color.gray,
            size: Theme.Icon.large
        )
    }

    /// Карточка вызова. Главный ярус — одна строка с ужатием, без переноса:
    /// длина чужого названия не имеет права двигать высоту окна.
    @ViewBuilder
    private var caller: some View {
        // Четыре ветки схлопнуты в одну: имя главным, номер под ним — ровно
        // то, что отдают `headline` и `secondaryNumber`. Разбор случая живёт в
        // `IncomingCallSubject`, а не здесь: вёрстка у всех четырёх была одна и
        // та же, и повторять её четырежды значило чинить маску в четырёх
        // местах вместо одного.
        //
        // Имя отвечает на «кто звонит», номер — только на «откуда»: увидев
        // «IT_test», оператор знает, с чем к нему идут, а «172» ему сначала
        // нужно вспомнить. Имени нет — главным становится номер: пустого
        // главного места не бывает.
        VStack(spacing: Theme.Metrics.hairSpacing) {
            // Имя крупно и в две строки, номер — 18, как в Windows 1.0.4.
            Text(subject.headline)
                .font(Theme.Text.incomingTitle)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)

            if let number = subject.secondaryNumber {
                Text(number)
                    .font(Theme.Text.incomingNumber)
                    .compatForeground(.secondary)
                    .lineLimit(1)
            }

            // Звонок по сделке: подсказка второй строкой в самой карточке,
            // золотистым — на обоях серая строка над кнопками не читалась.
            if subject == .selfCall {
                Text("Примите — и начнётся звонок клиенту")
                    .font(Theme.Text.incomingLine)
                    .compatForeground(Theme.Palette.connecting)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Metrics.tightSpacing)
            }
        }
        // Снятый вызов гаснет: принять его уже нельзя.
        .opacity(panel.takenNotice == nil ? 1 : 0.55)
        // Своя рамка у имени и номера — как внутренняя карточка Windows:
        // под ней обои, а текст читается на графите.
        // Поля 12 по бокам и 16 сверху и снизу, не ниже 116 — как
        // `IdentityCard` Windows и Linux (`Padding="12,16" MinHeight="116"`).
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(minHeight: 116)
        .graphiteSurface(.call, shadow: true)
        // Рамка непрозрачна при любой прозрачности обоев: имя не должно
        // спорить с картинкой.
        .environment(\.graphiteSurfaceOpacity, 1)
        // По центру окна, а не по левому краю (решение 27 августа 2026).
        //
        // Ярус вызова — единственное в окне, что читают с расстояния и в
        // спешке: окно появляется в случайной точке экрана, и глаз сначала
        // ищет его, а уже потом читает. У прижатого к левому краю имени точка
        // старта чтения гуляет вместе с длиной соседних ярусов; по центру она
        // стоит на месте — там же, где середина самого окна, которую глаз и
        // нашёл.
        //
        // Шапка и кнопки остаются по краям: они отвечают на другие вопросы и
        // читаются уже после того, как вызов опознан.
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            if challenge.hasChoice {
                prompt
                digitTargets
                declineButton
            } else {
                plainActions
            }
        }
    }

    /// Подсказка набрана одним кеглем целиком.
    ///
    /// Цифра внутри неё раньше говорила своим, четвёртым по счёту: 15 pt против
    /// 13 у остального текста. Два кегля в одной строке ради одного символа —
    /// разнобой, а не иерархия; выделяет её цвет, а не размер.
    private var prompt: some View {
        HStack(spacing: Theme.Metrics.tightSpacing) {
            Text("Чтобы ответить, нажмите")
                .compatForeground(.secondary)
            Text(String(challenge.answer))
                .compatForeground(.primary)
        }
        .font(Theme.Text.incomingLine)
    }

    private var digitTargets: some View {
        HStack(spacing: Theme.Metrics.sectionSpacing) {
            // Только мышью: цифра на клавиатуре вызов не принимает. Клавиатурное
            // нажатие не оставляет защите ни одного признака живого человека, и
            // отдельного пути для него здесь нет.
            ForEach(challenge.targets, id: \.self) { target in
                DigitTargetButton(digit: target) {
                    onAttempt(target)
                }
            }
        }
    }

    private var declineButton: some View {
        Button(action: onDecline) {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                CompatSymbol(name: "phone.down.fill")
                Text("Отклонить")
            }
            .font(Theme.Text.controlLabel)
            .compatForeground(Theme.Palette.decline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Metrics.incomingButtonPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .themedControlSurface()
        .hoverHighlight()
        .compatCancelShortcut()
        .compatAccessibilityLabel("Отклонить вызов")
    }

    /// Обычная пара кнопок, когда подтверждение цифрой выключено.
    private var plainActions: some View {
        HStack(spacing: Theme.Metrics.sectionSpacing) {
            // Кнопка активна с первого кадра: локальной задержки активации нет.
            FilledCallButton(
                title: NSLocalizedString("Ответить", comment: "кнопка в окне входящего"),
                icon: "Lucide/phone",
                surface: .answer,
                pulses: true
            ) {
                onAttempt(challenge.answer)
            }
            // У цели приёма намеренно нет действия доступности: `AXPress`
            // нажимает элемент вообще без событий мыши, и ни одна проверка
            // живого человека при этом не выполняется. Цена — недоступность
            // для screen reader именно этой кнопки; «Отклонить» и номер
            // звонящего доступность сохраняют, то есть отказаться от вызова
            // можно и без мыши.
            .compatAccessibilityHidden(true)

            FilledCallButton(
                title: NSLocalizedString("Отклонить", comment: "кнопка в окне входящего"),
                icon: "Lucide/phone-off",
                surface: .decline,
                action: onDecline
            )
            .compatCancelShortcut()
            .compatAccessibilityLabel("Отклонить вызов")
        }
    }
}

/// Одна цифровая цель: нейтральная поверхность, как у остальных элементов окна.
private struct DigitTargetButton: View {

    let digit: Character
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(String(digit))
                .font(Theme.Text.controlKey)
                .compatForeground(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Metrics.incomingButtonPadding)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .graphiteSurface(.control)
        .hoverHighlight(cornerRadius: Graphite.cornerRadius)
        // Нажать через Accessibility API нельзя — см. пояснение у «Ответить».
        .compatAccessibilityHidden(true)
    }
}

/// Кнопка с заливкой под цвет действия.
///
/// Заливка задана явно, а не через `.borderedProminent` с tint: окно намеренно
/// не забирает фокус, а системные акцентные стили в неактивном окне выцветают в
/// серый — кнопка ответа тогда выглядит выключенной.
private struct FilledCallButton: View {

    let title: String
    let icon: String
    let surface: Graphite.Surface
    /// Плавная пульсация «Ответить» — 1 → 0,87 → 1 за 2,4 с, как в Windows:
    /// геометрия не меняется, на наведении пульсация снимается.
    var pulses = false
    let action: @MainActor () -> Void

    @State private var isDimmed = false
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Metrics.sectionSpacing) {
                CompatSymbol(name: icon, size: 18)
                Text(title)
            }
            .font(Theme.Text.controlLabel)
            .compatForeground(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.incomingCallButtonHeight)
            .graphiteSurface(surface)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Graphite.cornerRadius)
        // Заметнее прежних 0,87 — как живой пульс кнопки в Windows.
        .opacity(pulses && isDimmed && !isHovered ? 0.7 : 1)
        .onHover { isHovered = $0 }
        .onAppear {
            guard pulses else { return }
            withAnimation(Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isDimmed = true
            }
        }
    }
}

/// Ручка переноса окна мышью.
///
/// Нужна, потому что `isMovableByWindowBackground` поверх SwiftUI не
/// работает: `NSHostingView` нажатие окну не отдаёт, и окно входящего с
/// 0.1.68 не двигалось вовсе, хотя флаг стоял. Перенос делает сам AppKit
/// (`performDrag`) — тот же системный цикл, что у полосы заголовка, со
/// снапом к краям и уведомлениями `didMove`, на которых панель запоминает
/// место.
///
/// Первое же нажатие работает (`acceptsFirstMouse`): окно неактивирующее и
/// ключевым не становится никогда, и без этого первый щелчок уходил бы на
/// активацию, которой не будет.
///
/// `onClick` — что делать на щелчке без переноса (копирование номера). Щелчок
/// от переноса отличает сдвиг курсора: пока рука не ушла дальше
/// `DragView.clickSlop`, это щелчок, дальше — перенос. Без `onClick` перенос
/// начинается сразу, как раньше.
struct WindowDragHandle: NSViewRepresentable {
    var onClick: (@MainActor () -> Void)?

    /// Подсказка под курсором. Здесь, а не `help` у SwiftUI: ручка лежит
    /// поверх, и наведение до вью под ней не доходит.
    var toolTip: String?

    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragView else { return }
        view.onClick = onClick
        view.toolTip = toolTip
        view.window?.invalidateCursorRects(for: view)
    }

    private final class DragView: NSView {
        /// Насколько может дрогнуть рука, чтобы щелчок остался щелчком.
        static let clickSlop: CGFloat = 3

        var onClick: (@MainActor () -> Void)?

        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
        }

        override func mouseDown(with event: NSEvent) {
            guard let window, let onClick else {
                window?.performDrag(with: event)
                return
            }
            // Свой короткий цикл: `performDrag` щелчок от переноса не отличает.
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if next.type == .leftMouseUp {
                    onClick()
                    return
                }
                let dx = next.locationInWindow.x - event.locationInWindow.x
                let dy = next.locationInWindow.y - event.locationInWindow.y
                if dx * dx + dy * dy > Self.clickSlop * Self.clickSlop {
                    window.performDrag(with: event)
                    return
                }
            }
        }
    }
}
