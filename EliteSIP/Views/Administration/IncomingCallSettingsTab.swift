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

    var body: some View {
        SettingsSection("Защита") {
            SettingsToggleRow("Защита от автокликеров", isOn: policy.isEnabled)
                // Место под вариант «значением управляет EliteDash»: пока
                // всегда активно, но интерфейс уже готов показать иное.
                .disabled(model.settings.incomingCall.isServerManaged)

            if model.settings.incomingCall.isServerManaged {
                SettingsNote("Значением управляет EliteDash.")
            } else if !isGuardOn {
                SettingsNote(
                    "Выключение фиксируется в журнале, а в M8 уедет в EliteDash.",
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

            SettingsRow("Минимальное смещение") {
                SettingSlider(value: policy.minimumTravel, range: 0...600, step: 25, unit: "pt")
            }
            .disabled(!model.settings.incomingCall.isRandomPositionEnabled)

            SettingsRow("Отступ от краёв") {
                SettingSlider(value: policy.screenMargin, range: 0...200, step: 8, unit: "pt")
            }

            SettingsNote("Ломает кликеры, которые бьют по постоянным координатам.")
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

            SettingsRow("Нужный путь курсора") {
                SettingSlider(value: policy.requiredCursorTravel, range: 0...200, step: 10, unit: "pt")
            }
            .disabled(!model.settings.incomingCall.requiresCursorMovement)

            SettingsNote("""
                CGEvent.post ставит курсор в точку одним событием — пути у такого движения нет.
                """)

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
                            callerNumber: "2929",
                            callerName: "AutoDialer",
                            ownNumber: model.settings.account.username,
                            queues: model.settings.queues
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
                            ownNumber: model.settings.account.username,
                            queues: model.settings.queues
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
                Вызов по сделке приходит с добавочного самого менеджера: Битрикс поднимает его \
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
