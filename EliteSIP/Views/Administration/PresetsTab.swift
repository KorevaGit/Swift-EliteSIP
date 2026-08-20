import AppKit
import SIPCore
import SwiftUI

/// Раздел «Предустановки»: сохранённые копии настроек рабочего места.
///
/// Отвечает на «как настроен такой-то отдел», а не «чьё это место». Снимается
/// один раз с настроенной машины, дальше на каждом следующем месте
/// администратор выбирает предустановку, вписывает номер — и получает готовое
/// место: кнопки, очереди, правила приёма, адрес АТС, стук, журнал.
///
/// Номера, пароля SIP и административного пароля в снимке нет — см.
/// `SettingsPreset`. Поэтому применение и спрашивает номер отдельно: без него
/// применять нечего.
struct PresetsTab: View {

    @EnvironmentObject private var model: AppModel

    @State private var newName = ""
    @State private var pendingRemoval: SettingsPreset?

    /// Что сказать после выгрузки: куда лёг файл или почему не лёг.
    @State private var notice: String?

    /// Что и куда применяем. Живёт здесь, а не в модели: до нажатия «Применить»
    /// это ещё не правка, а намерение, и «Отменить» ему не нужно.
    /// У какой предустановки раскрыто «что внутри». Одна за раз: две
    /// развёрнутые карточки не сравнивают, а листают.
    @State private var inspectingID: UUID?

    @State private var applyingID: UUID?
    @State private var number = ""
    @State private var targetID: UUID?

    var body: some View {
        SettingsSection("Эта машина") {
            SettingsRow("Настроена") {
                Text(originText)
                    .compatForeground(
                        model.settings.appliedPresetName.isEmpty
                            ? Theme.Palette.textSecondary : Theme.Palette.textPrimary
                    )
            }

            SettingsNote("""
                Здесь видно, по какому шаблону заведено это место. Правки, сделанные \
                после применения, тут не отражаются: строка отвечает на «с чего начали», \
                а не «что сейчас».
                """)
        }

        // Заводские предустановки — те, что предлагает мастер первого запуска.
        // В списке ниже их не было никогда: они живут в бандле, а не в файле
        // настроек, — и администратор, открывший раздел на готовой машине,
        // видел пустоту вместо «Менеджера», по которому она и заведена.
        SettingsSection("Заводские") {
            ForEach(Provisioning.factoryPresets, id: \.name) { factory in
                factoryCard(factory)
            }

            SettingsNote("""
                Приезжают вместе с приложением и правке не подлежат — их меняют пересборкой. \
                Чтобы отступить от заводской на одной машине, настройте её как надо и снимите \
                свою предустановку ниже.
                """)
        }

        SettingsSection("Снять с этой машины") {
            SettingsRow("Название") {
                TextField("Например: Менеджер", text: $newName)
            }

            SettingsButtonsRow {
                Button("Снять предустановку") { capture() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // Загрузка была заявлена в M8 и не существовала полтора месяца:
                // выгрузка файлом работала, а прочитать этот файл было нечем — то
                // есть путь «настроить одну машину, снять шаблон, разнести по
                // остальным» обрывался на середине. Появилась 17 августа 2026
                // вместе с форматом `.elitesip`.
                Button("Загрузить из файла…") { importPreset() }
                    .compatHelp("Прочитать файл предустановки, снятой на другой машине")
            }

            SettingsNote("""
                Снимок берётся с того, что сейчас в окне, — включая несохранённое. \
                В него входит всё, кроме номера, пароля SIP и \
                административного пароля: предустановка ходит между машинами, а номер там \
                у каждой свой, и пароль, размноженный из шаблона, паролем быть перестаёт.
                """)
        }

        SettingsSection("Предустановки") {
            if model.settings.presets.isEmpty {
                SettingsNote("""
                    Пока ни одной. Настройте это рабочее место как образцовое и снимите с \
                    него предустановку — дальше её хватит, чтобы завести такое же место \
                    одним номером.
                    """)
            } else {
                ForEach(model.settings.presets) { preset in
                    presetCard(preset)
                }
            }

            if let notice {
                SettingsNote(verbatim: notice)
            }
        }
        .alert(item: $pendingRemoval) { preset in
            Alert(
                title: Text("Удалить «\(preset.name)»?"),
                message: Text("Настройки машин, заведённых по ней, останутся как есть."),
                primaryButton: .destructive(Text("Удалить")) { model.removePreset(preset.id) },
                secondaryButton: .cancel(Text("Оставить"))
            )
        }
    }

    // MARK: - Карточка

    @ViewBuilder
    private func presetCard(_ preset: SettingsPreset) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                TextField("", text: Binding(
                    get: { preset.name },
                    set: { model.renamePreset(preset.id, to: $0) }
                ))
                .frame(maxWidth: 220)

                Text(summary(of: preset))
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)

                Spacer(minLength: 0)

                Button(applyingID == preset.id ? "Не применять" : "Применить…") {
                    if applyingID == preset.id {
                        applyingID = nil
                    } else {
                        applyingID = preset.id
                        number = ""
                        targetID = nil
                    }
                }

                Button(inspectingID == preset.id ? "Свернуть" : "Что внутри…") {
                    inspectingID = inspectingID == preset.id ? nil : preset.id
                }
                .compatHelp("Показать, что войдёт в машину при применении")

                Button("Выгрузить…") { export(preset) }
                    .compatHelp("Сохранить файл предустановки — перенести её на другую машину")

                Button {
                    pendingRemoval = preset
                } label: {
                    CompatSymbol(name: "trash")
                }
                .buttonStyle(.plain)
                .compatHelp("Удалить предустановку")
            }

            if inspectingID == preset.id {
                contents(of: preset.snapshot)
            }

            if applyingID == preset.id {
                applyForm(preset)
            }
        }
    }

    // MARK: - Заводская карточка

    /// Заводская предустановка: только имя и просмотр. Ни переименования, ни
    /// удаления, ни выгрузки — она приезжает с приложением.
    @ViewBuilder
    private func factoryCard(_ factory: Provisioning.FactoryPreset) -> some View {
        let snapshot = factory.snapshot(site: model.settings.profiles.active.site)
        VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                Text(factory.name)

                Text(summary(of: snapshot))
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)

                Spacer(minLength: 0)

                Button(inspectingID == factoryID(factory) ? "Свернуть" : "Что внутри…") {
                    inspectingID = inspectingID == factoryID(factory) ? nil : factoryID(factory)
                }
            }

            if inspectingID == factoryID(factory) {
                contents(of: snapshot)
            }
        }
    }

    /// Заводским предустановкам `UUID` не нужен, а раскрытой карточке — нужен.
    /// Берётся из имени, чтобы не заводить состояние второго вида.
    private func factoryID(_ factory: Provisioning.FactoryPreset) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", abs(factory.name.hashValue % 1_000_000_000_000)))")
            ?? UUID()
    }

    // MARK: - Что внутри

    /// Просмотр содержимого — без правки.
    ///
    /// Правку решено не делать (19 августа 2026): предустановка редактируется
    /// там же, где и настраивается, — на образцовой машине, с которой её
    /// снимают. Форма правки шаблона завела бы второй способ менять те же
    /// значения, и два способа рано или поздно расходятся.
    @ViewBuilder
    private func contents(of snapshot: AppSettings) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            contentLine("АТС", snapshot.profiles.active.account.domain)
            contentLine(
                "Клавиши",
                snapshot.dtmf.macros.isEmpty
                    ? NSLocalizedString("нет", comment: "пусто в просмотре предустановки")
                    : snapshot.dtmf.macros.map(\.title).joined(separator: ", ")
            )
            contentLine(
                "Очереди",
                snapshot.queues.queues.isEmpty
                    ? NSLocalizedString("нет", comment: "пусто в просмотре предустановки")
                    : snapshot.queues.queues.map(\.number).joined(separator: ", ")
            )
            contentLine(
                "Сетка",
                String(
                    format: NSLocalizedString("%1$lld в ряду · %2$lld тчк", comment: "сетка клавиш в просмотре предустановки"),
                    snapshot.dtmf.macroColumns,
                    snapshot.dtmf.macroHeight
                )
            )
        }
        .font(.footnote)
        .padding(.leading, Theme.Metrics.contentPadding)
    }

    private func contentLine(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Metrics.elementSpacing) {
            Text(title)
                .compatForeground(Theme.Palette.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .compatForeground(Theme.Palette.textPrimary)
            Spacer(minLength: 0)
        }
    }

    /// Чем настроена машина — строкой для человека.
    private var originText: String {
        let name = model.settings.appliedPresetName
        guard !name.isEmpty else {
            return NSLocalizedString("вручную, без предустановки", comment: "происхождение настроек машины")
        }
        guard let date = model.settings.appliedPresetAt else { return name }
        return String(
            format: NSLocalizedString("по предустановке «%1$@», %2$@", comment: "происхождение настроек машины"),
            name,
            HistoryDate.stamp(date)
        )
    }

    /// Форма применения: куда и с каким номером.
    private func applyForm(_ preset: SettingsPreset) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            SettingsRow("Профиль") {
                Picker("", selection: $targetID) {
                    Text("Новый профиль").tag(UUID?.none)
                    ForEach(model.settings.profiles.profiles) { profile in
                        Text(title(of: profile)).tag(UUID?.some(profile.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            SettingsRow("Номер") {
                // Обычное поле, а не `NumberField`: тот собран для набора на
                // панели — забирает фокус при появлении и живёт по правилам
                // дайлпада. Здесь это строка настроек, как номер очереди рядом.
                TextField("номер", text: $number)
                    .frame(maxWidth: 120)
            }

            SettingsButtonsRow {
                Button("Применить") {
                    model.applyPreset(preset, number: number, to: targetID)
                    applyingID = nil
                }
                .compatProminentButtonStyle()
                .disabled(number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            SettingsNote("""
                Перезапишет всё, что входит в предустановку, — и настройки машины, и \
                выбранный профиль. Не тронет: номера и пароли остальных профилей, пароль \
                выбранного профиля и административный пароль. Логин \
                приравнивается к номеру.
                """)
        }
        .padding(.leading, Theme.Metrics.contentPadding)
    }

    // MARK: - Подписи

    private func summary(of preset: SettingsPreset) -> String { summary(of: preset.snapshot) }

    private func summary(of snapshot: AppSettings) -> String {
        let account = snapshot.profiles.active.account
        let macros = snapshot.dtmf.macros.count
        let queues = snapshot.queues.queues.count
        return String(
            format: NSLocalizedString("%1$@ · %2$lld макр. · %3$lld очер.", comment: "что внутри предустановки"),
            account.domain,
            macros,
            queues
        )
    }

    private func title(of profile: SIPProfile) -> String {
        let label = profile.label.isEmpty ? profile.account.username : profile.label
        return label.isEmpty ? NSLocalizedString("без номера", comment: "профиль без номера") : label
    }

    /// Выгрузка предустановки файлом.
    ///
    /// Ради этого предустановки и заводились: настроить одно место, снять
    /// шаблон и разнести его по остальным. Внутри — тот же JSON, что и в
    /// настройках, и ровно так же без номера, пароля SIP и блока доступа: файл
    /// уезжает на чужую машину, и класть в него секреты нельзя тем более.
    ///
    /// С 17 августа 2026 файл пишется в формате `.elitesip` — с заголовком и
    /// версией, — а не сырым `SettingsPreset` под именем `.elitesip-preset.json`.
    /// Заголовок нужен читающей стороне: без него чужой JSON того же вида
    /// прочитался бы терпимыми декодерами в пустые настройки, и «файл не наш»
    /// выглядело бы как «файл пустой».
    private func export(_ preset: SettingsPreset) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = EliteSIPDocument.suggestedName(.preset, label: preset.name)
        panel.prompt = NSLocalizedString("Выгрузить", comment: "кнопка в окне сохранения файла")
        // Рабочий стол: оттуда файл переносят на флешку или прикладывают к
        // письму. Тот же выбор, что у выгрузки настроек в «Обслуживании».
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try EliteSIPDocument.encode(preset: preset).write(to: url, options: .atomic)
            notice = String(format: NSLocalizedString("Предустановка выгружена в %@.", comment: "итог выгрузки предустановки"), url.lastPathComponent)
        } catch {
            notice = String(format: NSLocalizedString("Не удалось выгрузить: %@", comment: "выгрузка предустановки не удалась"), error.localizedDescription)
        }
    }

    /// Загрузка предустановки из файла.
    ///
    /// Ложится в тот же черновик «Управления», что и остальные правки: на диск
    /// ничего не уходит до «Сохранить», и «Отменить» возвращает как было. Иначе
    /// чужой файл менял бы настройки машины помимо того порядка, который в этом
    /// окне заведён специально.
    ///
    /// Конфигурация вместо предустановки отбивается отдельным сообщением: файлы
    /// лежат рядом, называются похоже, а последствия у них разные — слепок несёт
    /// чужой добавочный и пароль.
    private func importPreset() {
        // `NSOpenPanel`, а не `fileImporter`: тот появился в macOS 11, а срез
        // x86_64 живёт с Catalina.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = [EliteSIPDocument.fileExtension]
        panel.prompt = NSLocalizedString("Загрузить", comment: "кнопка в окне выбора файла")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch try EliteSIPDocument.read(try Data(contentsOf: url)) {
            case .preset(let preset):
                model.addPreset(preset)
                notice = String(
                    format: NSLocalizedString(
                        "Предустановка «%@» загружена. Она появится на машине после «Сохранить».",
                        comment: "итог загрузки предустановки"
                    ),
                    preset.name
                )
            case .config:
                notice = NSLocalizedString(
                    "Это конфигурация, а не предустановка: в ней есть номер и пароль. Такой файл принимает мастер первоначальной настройки.",
                    comment: "выбран файл конфигурации вместо предустановки"
                )
            }
        } catch let failure as EliteSIPDocument.Failure {
            notice = failure.title
        } catch {
            notice = EliteSIPDocument.Failure.damaged.title
        }
    }

    private func capture() {
        model.capturePreset(named: newName)
        newName = ""
    }
}
