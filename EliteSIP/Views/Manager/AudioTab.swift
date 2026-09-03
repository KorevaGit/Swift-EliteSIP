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

    /// Есть ли что показывать. Тракт открыт либо разговором, либо самопроверкой;
    /// между ними уровни лежат на нуле, и полоска врала бы про микрофон.
    private var showsLevels: Bool { model.isInCall || model.isSelfTestRunning }

    var body: some View {
        SettingsSection("Звук") {
            AudioDeviceRow(
                title: "Микрофон",
                systemTitle: "Системный по умолчанию",
                devices: inputs,
                defaultName: defaultInputName,
                uid: Binding(
                    get: { model.settings.audio.inputDeviceUID },
                    set: { model.settings.audio.inputDeviceUID = $0 }
                ),
                rememberedName: Binding(
                    get: { model.settings.audio.inputDeviceName },
                    set: { model.settings.audio.inputDeviceName = $0 }
                )
            )

            // Ползунок стоит под своим устройством, а не отдельным блоком
            // «Громкость» внизу страницы. Отдельным блоком обе подписи
            // пришлось бы называть «Микрофон» и «Наушники» второй раз, и на
            // странице стало бы по две одинаковых строки. Здесь «Усиление»
            // читается как продолжение строки над ним и другого толкования не
            // имеет.
            //
            // Ручка своя, а не системная: у микрофона на половине гарнитур
            // регулятора нет вовсе, и «меня плохо слышно» до сих пор лечилось
            // только сменой гарнитуры.
            //
            // При включённом автоусилении ручка гаснет, и это не придирка к
            // виду: движок отдаёт уровень входа `VoiceProcessingIO`, тот его
            // тут же переставляет по своему счёту, и ползунок оказывался
            // регулятором, который двигается и ничего не меняет. Оператор при
            // этом честно тянул его вправо, слушал «меня всё так же плохо
            // слышно» и делал единственный доступный вывод — что сломано
            // приложение.
            SettingsRow("Усиление") {
                SettingSlider(
                    value: Binding(
                        get: { model.settings.audio.microphoneGain },
                        set: { model.settings.audio.microphoneGain = $0 }
                    ),
                    range: AppSettings.AudioSettings.microphoneGainRange,
                    step: 0.05,
                    unit: nil
                )
                .disabled(model.settings.audio.automaticGainControl)
            }

            // Почему ручка серая — здесь, а не подсказкой при наведении:
            // подсказок в интерфейсе нет, и «контрол серый и молчит» —
            // худший вид отказа. Строка появляется только тогда, когда
            // объяснять есть что.
            if model.settings.audio.automaticGainControl {
                SettingsNote("Усиление считает система: чтобы поставить его руками, выключите автоматическую регулировку ниже.")
            }

            if showsLevels {
                InputLevelMeter(levels: model.audioLevels, title: "Уровень")
            }

            AudioDeviceRow(
                title: "Наушники",
                systemTitle: "Системные по умолчанию",
                devices: outputs,
                defaultName: defaultOutputName,
                uid: Binding(
                    get: { model.settings.audio.outputDeviceUID },
                    set: { model.settings.audio.outputDeviceUID = $0 }
                ),
                rememberedName: Binding(
                    get: { model.settings.audio.outputDeviceName },
                    set: { model.settings.audio.outputDeviceName = $0 }
                )
            )

            // Выше единицы ползунок не идёт: микшер громче не умеет, а ручка,
            // которая двигается и ничего не меняет, хуже её отсутствия.
            // Системная громкость сюда не годится — она меняет звук всей
            // машины, а тише надо сделать только собеседника.
            SettingsRow("Громкость") {
                SettingSlider(
                    value: Binding(
                        get: { model.settings.audio.playbackVolume },
                        set: { model.settings.audio.playbackVolume = $0 }
                    ),
                    range: AppSettings.AudioSettings.playbackVolumeRange,
                    step: 0.05,
                    unit: nil
                )
            }

            if showsLevels {
                OutputLevelMeter(levels: model.audioLevels, title: "Уровень")
            } else {
                // Полоска, лежащая на нуле потому, что мерить нечего, читается
                // как сломанный микрофон. Пока мерить нечего — слова вместо неё.
                SettingsNote("""
                    Уровни появятся здесь в разговоре и во время проверки ниже: \
                    по ним видно, что уходит в линию и что приходит из неё.
                    """)
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
        if model.isInCall {
            return NSLocalizedString("Во время разговора микрофон занят.", comment: "почему самопроверка недоступна")
        }
        return nil
    }

    private var needsAggregate: Bool {
        AudioDeviceCatalog.needsAggregate(
            inputUID: model.settings.audio.inputDeviceUID,
            outputUID: model.settings.audio.outputDeviceUID
        )
    }
}

/// Строка выбора звукового устройства — микрофона или наушников.
///
/// Один тип на обе стороны, а не две копии подряд: правил здесь три (живой
/// список, строка пропавшего устройства, «в звонке: …»), и двум копиям есть где
/// разойтись — первая же правка одной из них это и сделала бы.
///
/// **Пропавшее устройство остаётся в списке.** Вынули гарнитуру — и до этой
/// правки поле становилось пустым и невыбранным: сохранён `uid`, а строки с
/// таким тегом в списке больше нет, и AppKit честно рисовать было нечего.
/// Выглядело это как сбитая настройка, хотя настройка стояла на месте и
/// разговор шёл — движок не находит `uid` и берёт системное умолчание
/// (`AudioDeviceCatalog.device(uid:)`).
///
/// Сбрасывать выбор на «системное» в этот момент — как просили сначала — было
/// бы хуже. Гарнитуру вынимают и втыкают по десять раз на дню, и сброс означал
/// бы, что после каждого возвращения её надо выбирать заново. Поэтому выбор
/// сохраняется, а вместо пустоты человеку говорится ровно то, что есть:
/// устройство выбрано, сейчас его нет, звонок идёт через системное.
struct AudioDeviceRow: View {

    let title: LocalizedStringKey

    /// Подпись пункта «отдать выбор системе». У микрофона и наушников она в
    /// разном роде, поэтому приходит снаружи, а не собирается здесь.
    let systemTitle: LocalizedStringKey

    let devices: [AudioDevice]

    /// Во что «системное по умолчанию» обращается на этой машине прямо сейчас.
    let defaultName: String?

    @Binding var uid: String?

    /// Имя, под которым устройство выбирали. См. `AppSettings.AudioSettings`:
    /// живёт только ради этой строки и ни на что не влияет.
    @Binding var rememberedName: String

    /// Выбранное устройство сейчас недоступно: вынули, выключили, уснуло.
    private var isMissing: Bool {
        guard let uid else { return false }
        return !devices.contains { $0.uid == uid }
    }

    /// Как назвать пропавшее устройство в списке.
    ///
    /// Имя помним с момента выбора. У файла настроек, записанного до этой
    /// правки, имени нет — тогда общее слово: оно хуже имени, но несравнимо
    /// лучше пустого поля, и живёт ровно до первого осознанного выбора.
    private var missingTitle: String {
        let name = rememberedName.isEmpty
            ? NSLocalizedString(
                "Выбранное устройство",
                comment: "имя пропавшего звукового устройства неизвестно")
            : rememberedName
        return String(
            format: NSLocalizedString(
                "%@ — отключено",
                comment: "устройство выбрано, но сейчас недоступно"),
            name
        )
    }

    var body: some View {
        // Явный стек с тем же шагом, что у блока настроек: строка и пояснение
        // под ней — два элемента страницы, и промежуток между ними обязан
        // совпасть с промежутком между соседними строками.
        VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            SettingsRow(title) {
                Picker("", selection: Binding(
                    get: { uid },
                    set: { chosen in
                        uid = chosen
                        // Имя пишется вместе с выбором и только здесь: другого
                        // момента, когда устройство заведомо на месте и его
                        // можно спросить, у нас нет.
                        rememberedName = chosen.flatMap { picked in
                            devices.first { $0.uid == picked }?.name
                        } ?? ""
                    }
                )) {
                    Text(systemTitle).tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    // Строка пропавшего устройства. Без неё у выбранного `uid`
                    // нет своего тега в списке — и поле пустеет.
                    if isMissing, let uid {
                        Text(verbatim: missingTitle).tag(String?.some(uid))
                    }
                }
                .labelsHidden()
            }

            // Что уйдёт в звонок на самом деле. «Системный по умолчанию» — это
            // правило, а не устройство, и ответ у него меняется вместе с
            // наушниками. Оператор спрашивает «через что меня будет слышно», и
            // название правила на этот вопрос не отвечает.
            //
            // У пропавшего устройства эта строка нужна тем более: она и есть
            // ответ на «а через что я тогда говорю сейчас».
            if uid == nil || isMissing, let defaultName {
                SettingsResolvedValue("в звонке: \(defaultName)")
            }
        }
    }
}
