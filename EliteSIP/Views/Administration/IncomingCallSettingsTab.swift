import CallGuard
import SwiftUI

/// Раздел «Входящие»: политика защиты от автокликеров целиком.
///
/// Единственный раздел, состав которого этап 5 не менял. Из него ушёл только
/// блок рингтона — он менеджерский по смыслу («звук на своём рабочем месте
/// человек выбирает сам») и всё это время дублировал менеджерскую страницу,
/// сидя внутри закрытого раздела.
struct IncomingCallSettingsTab: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var incomingCall: IncomingCallPanel

    private var policy: Binding<CallGuardPolicy> {
        Binding(
            get: { model.settings.incomingCall },
            set: { model.settings.incomingCall = $0 }
        )
    }

    private var isGuardOn: Bool { model.settings.incomingCall.isEnabled }

    /// Переключатель «Авто ↔ Вручную» слоя случайности.
    ///
    /// Возврат на «Авто» **переписывает сами числа**, а не только признак.
    /// Иначе ползунок остался бы стоять там, куда его увели, и показывал бы не
    /// то, чем защита пользуется: `normalized` на «Авто» берёт заводские
    /// значения независимо от записанного. Расхождение показанного и
    /// действующего — ровно та поломка, от которой этот переключатель заведён.
    private var randomnessByHand: Binding<Bool> {
        Binding(
            get: { model.settings.incomingCall.tunesRandomnessByHand },
            set: { byHand in
                model.settings.incomingCall.tunesRandomnessByHand = byHand
                guard !byHand else { return }
                let factory = CallGuardPolicy()
                model.settings.incomingCall.minimumTravel = factory.minimumTravel
                model.settings.incomingCall.screenMargin = factory.screenMargin
            }
        )
    }

    /// То же для слоя признаков живого человека.
    private var livenessByHand: Binding<Bool> {
        Binding(
            get: { model.settings.incomingCall.tunesLivenessByHand },
            set: { byHand in
                model.settings.incomingCall.tunesLivenessByHand = byHand
                guard !byHand else { return }
                let factory = CallGuardPolicy()
                model.settings.incomingCall.requiredCursorTravel = factory.requiredCursorTravel
                model.settings.incomingCall.requiredCursorSamples = factory.requiredCursorSamples
            }
        )
    }

    /// Один текст на оба слоя: причина у них общая, и разводить её двумя
    /// формулировками значило бы завести два объяснения одного правила.
    private var tuningNote: LocalizedStringKey {
        """
        На «Авто» стоят проверенные значения, а ползунки заперты: колесо мыши над \
        незапертым ползунком меняет защиту молча, и заметить это потом не по чему. \
        «Вручную» отпирает их и отдаёт числа тому, кто их выставил.
        """
    }

    var body: some View {
        SettingsSection("Защита") {
            // Выключатель не запирается, даже когда значение приезжает из
            // панели, — и это отмена решения M9.
            //
            // Замок стоял здесь один на всё окно. Ни DTMF, ни конференция, ни
            // адреса АТС, ни стук — всё то же самое, приезжающее предустановкой
            // — не заперты ничем и правятся свободно; заперта была одна
            // защита. Поле `isServerManaged` завели в M7c как «место под
            // вариант 1», а в M9 подключили к единственной вкладке, до которой
            // дошли руки, — то есть замок был не решением, а следом работ.
            //
            // Защищал он при этом нечего: правка ЛЮБОГО управляемого поля
            // живёт ровно до следующей выкладки предустановки, потому что
            // машина применяет только ревизию новее применённой. Запертое поле
            // отличалось от незапертых не судьбой правки, а лишь тем, что
            // правку нельзя было внести.
            //
            // Главное же — окно «Управление» затем и существует, чтобы
            // отвязаться от синхронизации и перенастроить место руками.
            // Требовать ради одной настройки снять машину с панели целиком —
            // вместе с адресом АТС, стуком и макросами — значит предлагать
            // кувалду вместо отвёртки.
            SettingsToggleRow("Защита от автокликеров", isOn: policy.isEnabled)

            // Сказать правду про судьбу правки всё равно надо: администратор,
            // выключивший защиту на управляемой машине, должен знать, что
            // следующая выкладка предустановки вернёт её.
            if model.settings.incomingCall.isServerManaged {
                SettingsNote("""
                    Значение приезжает из панели предустановкой \
                    «\(model.settings.panel.presetName)». Правка здесь \
                    действует сразу и держится до следующей выкладки этой \
                    предустановки — потом вернётся то, что задано в панели. \
                    Чтобы правка осталась навсегда, снимите «Слушать панель» \
                    в разделе «Аккаунт» или поменяйте значение в самой панели.
                    """)
            }

            if !isGuardOn {
                SettingsNote(
                    "Выключение фиксируется в журнале: каждый вызов помечается как принятый без защиты.",
                    isAlarming: true
                )
            }

            SettingsNote("""
                Автокликер принимает лид быстрее коллег, не находясь за рабочим местом, \
                и лид уходит в тишину.
                """)
        }

        SettingsSection("Случайность") {
            SettingsToggleRow("Случайная позиция окна", isOn: policy.isRandomPositionEnabled)

            SettingsRow("Расстояния") {
                TuningPicker(isByHand: randomnessByHand)
            }

            SettingsRow("Минимальное смещение") {
                SettingSlider(value: policy.minimumTravel, range: 0...600, step: 25, unit: "pt")
            }
            .disabled(
                !model.settings.incomingCall.isRandomPositionEnabled
                    || !model.settings.incomingCall.tunesRandomnessByHand
            )

            SettingsRow("Отступ от краёв") {
                SettingSlider(value: policy.screenMargin, range: 0...200, step: 8, unit: "pt")
            }
            .disabled(!model.settings.incomingCall.tunesRandomnessByHand)

            SettingsNote("Ломает кликеры, которые бьют по постоянным координатам.")

            SettingsNote(tuningNote)
        }
        .disabled(!isGuardOn)

        SettingsSection("Подтверждение цифрой") {
            SettingsToggleRow("Цифровое подтверждение", isOn: Binding(
                get: { model.settings.incomingCall.targetCount > 1 },
                set: { model.settings.incomingCall.targetCount = $0 ? 3 : 1 }
            ))

            if model.settings.incomingCall.targetCount > 1 {
                SettingsRow("Целей на выбор") {
                    Picker("", selection: policy.targetCount) {
                        ForEach(2...5, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }
            }

            SettingsNote("""
                Вместо кнопки «Ответить» показывается ряд цифр, и вызов принимает только одна \
                из них — названная в подписи. Ломает кликер, который ищет кнопку по картинке. \
                Выключено по умолчанию: это внимание оператора на каждом вызове, а случайная \
                позиция окна обходится ему бесплатно.
                """)
        }
        .disabled(!isGuardOn)

        SettingsSection("Признаки живого человека") {
            SettingsToggleRow("Требовать движения курсора", isOn: policy.requiresCursorMovement)

            SettingsRow("Расстояния") {
                TuningPicker(isByHand: livenessByHand)
            }

            SettingsRow("Нужный путь курсора") {
                SettingSlider(value: policy.requiredCursorTravel, range: 0...200, step: 10, unit: "pt")
            }
            .disabled(
                !model.settings.incomingCall.requiresCursorMovement
                    || !model.settings.incomingCall.tunesLivenessByHand
            )

            SettingsNote("""
                CGEvent.post ставит курсор в точку одним событием — пути у такого движения нет.
                """)

            SettingsNote(tuningNote)

            SettingsToggleRow("Отклонять синтетические нажатия", isOn: policy.rejectsSyntheticEvents)

            SettingsNote("""
                Признак подделывается, поэтому по умолчанию он только пишется в отчёт.
                """)
        }
        .disabled(!isGuardOn)

        SettingsSection("Проверка") {
            SettingsButtonsRow {
                Button {
                    incomingCall.show(
                        subject: IncomingCallSubject(
                            // Боевая форма раздачи, а не выдуманная: добавочный
                            // колл-центра и просьба автоответа. Проверка
                            // показывает ровно то, что оператор увидит на живом
                            // вызове, — ради этого её и открывают.
                            callerNumber: "712",
                            callerName: "Call_Center",
                            requestsAutoAnswer: true,
                            ownNumber: model.settings.account.username
                        ),
                        policy: model.settings.incomingCall,
                        onAnswer: {},
                        onDecline: {}
                    )
                } label: {
                    CompatLabel(title: "Показать окно для проверки", symbol: "bell.badge")
                }

                // Второй показ, а не переключатель в первом: у звонка по сделке
                // другой заголовок и своя подсказка, и увидеть их иначе нельзя
                // — случай приходит из Битрикса, а не из настроек. Номер
                // подставляется настоящий, свой: так проверка заодно
                // показывает, что добавочный вообще опознаётся.
                Button {
                    incomingCall.show(
                        subject: IncomingCallSubject(
                            callerNumber: model.settings.account.username,
                            callerName: nil,
                            ownNumber: model.settings.account.username
                        ),
                        policy: model.settings.incomingCall,
                        onAnswer: {},
                        onDecline: {}
                    )
                } label: {
                    CompatLabel(title: "Показать вызов по сделке", symbol: "phone.arrow.right")
                }
                .disabled(model.settings.account.username.isEmpty)
            }

            SettingsNote("""
                Вызов по сделке приходит с номера самого менеджера: Битрикс поднимает его \
                и только потом набирает клиента. Настройки для этого не нужны — номер берётся \
                из активного профиля.
                """)

            if let report = model.lastGuardReport {
                SettingsRow("Последний вызов") {
                    Text(report.summary)
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// «Авто ↔ Вручную» одной парой сегментов.
///
/// Сегменты, а не тумблер «Настроить вручную»: у тумблера включённое состояние
/// читается как «сделано лучше», а здесь оба положения равноправны — заводское
/// и своё. Тот же сегментированный вид, что у темы и языка в настройках
/// менеджера: третьего вида переключателя из двух вариантов в приложении нет.
private struct TuningPicker: View {

    @Binding var isByHand: Bool

    var body: some View {
        Picker("", selection: $isByHand) {
            Text("Авто").tag(false)
            Text("Вручную").tag(true)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 180, alignment: .leading)
    }
}
