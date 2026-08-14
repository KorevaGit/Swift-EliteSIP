import MediaCore
import SwiftUI

/// Устройства, эхоподавление и самопроверка голоса.
///
/// Первый раздел настроек, потому что меняется чаще остальных: наушники
/// переключают в течение дня, а тему выбирают один раз.
///
/// Эхоподавление как таковое не выключается: это системный `VoiceProcessingIO`,
/// и он либо есть, либо macOS его не даёт (разные устройства). Выключателем
/// остаётся автоусиление — единственное, что в этом блоке действительно спорно
/// на хорошей гарнитуре.
struct AudioTab: View {

    @EnvironmentObject private var model: AppModel

    /// Устройства и то, во что обращается «системное по умолчанию», берутся
    /// готовыми у модели — не спрашиваются у CoreAudio на появлении раздела.
    ///
    /// Это и была видимая задержка: опрос из `onAppear` успевал не к первой
    /// отрисовке, а к следующей, и оба выключателя съезжали вниз на глазах —
    /// под ними появлялись строки «в звонке: …», которых в первом кадре не
    /// было. Разбор и снимок — в `AppModel.AudioCatalog`.
    private var inputs: [AudioDevice] { model.audioCatalog.inputs }
    private var outputs: [AudioDevice] { model.audioCatalog.outputs }
    private var defaultInputName: String? { model.audioCatalog.defaultInputName }
    private var defaultOutputName: String? { model.audioCatalog.defaultOutputName }

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
                SettingsNote(verbatim: status)
            }
        }
        .onDisappear {
            // Уход с экрана обязан закрыть микрофон: иначе он остаётся открытым
            // до конца пяти секунд уже после того, как настройки закрыли. С
            // разбором на разделы это стало срабатывать и при переключении
            // раздела — и это правильно: ушёл с «Звука» — отпусти микрофон.
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
}
