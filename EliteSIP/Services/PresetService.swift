import CryptoKit
import Foundation
import PanelLink

/// Линия предустановок (M9): как правки из панели доезжают до рабочего места.
///
/// Отдельная от Sparkle линия — она возит данные, а не код, — но **будильник у
/// них общий**: канал один, и два независимых срока на нём разошлись бы через
/// полгода. Такт задаёт `UpdateService`, эта служба только делает работу.
///
/// **Приложение к панели не обращается.** Оно тянет подписанный файл с того же
/// канала раздачи, что и обновления. Панель стоит на локальном сервере конторы
/// и наружу не смотрит; узнаёт она о машинах только по следам, которые
/// оставляет раздача. Ни постоянного соединения, ни команд с сервера, ни
/// телеметрии здесь нет и не появится.
///
/// **Нет связи — работает локальный режим, и это не аварийное состояние.**
/// Требование M7c остаётся в силе: софтфон нужен для звонков, а не для того,
/// чтобы синхронизироваться.
@MainActor
final class PresetService {

    /// Открытый ключ линии из `Info.plist`.
    ///
    /// Пустой — линия выключена целиком. Так и задумано: ключ вписывается перед
    /// первой выкладкой, и до тех пор приложение обязано работать, а не падать.
    private let publicKey: Curve25519.Signing.PublicKey?

    /// Настройки машины: прочитать применённую ревизию и записать новую.
    private let settings: () -> AppSettings

    /// Применить обновлённые настройки. Замыкание, а не ссылка на модель: этой
    /// службе о ней знать нечего.
    private let apply: (AppSettings, String) -> Void

    /// Можно ли применять прямо сейчас.
    ///
    /// Обновление предустановки **обязательное**, кнопки «Отложить» нет и быть
    /// не должно: без него меняется адрес АТС, и машина просто не звонит. Но
    /// ждать оно умеет, и поводов ровно два:
    ///
    /// 1. **Идёт разговор.** Правило то же, что у обновлений в M7h.
    /// 2. **Открыто «Управление».** Там правки копятся в памяти и записываются
    ///    разом по «Сохранить», а «Отменить» возвращает снимок, снятый на
    ///    входе. Применить предустановку в этот момент значит либо потерять её
    ///    по «Отменить», либо затереть ею несохранённые правки администратора —
    ///    и в обоих случаях человек увидит не то, что делал.
    private let isBlocked: () -> Bool

    private let log: (String) -> Void

    /// Отложенное применение: файл проверен и разобран, но человек говорит.
    private var deferred: PresetBundle.Entry?

    private var isFetching = false

    init(settings: @escaping () -> AppSettings,
         apply: @escaping (AppSettings, String) -> Void,
         isBlocked: @escaping () -> Bool,
         log: @escaping (String) -> Void) {
        self.settings = settings
        self.apply = apply
        self.isBlocked = isBlocked
        self.log = log

        let raw = (Bundle.main.object(forInfoDictionaryKey: "ESPresetsPublicKey") as? String) ?? ""
        if raw.isEmpty {
            publicKey = nil
        } else if let data = Data(base64Encoded: raw),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) {
            publicKey = key
        } else {
            publicKey = nil
        }
    }

    /// Спросить канал. Зовётся общим циклом `UpdateService`.
    func check() {
        guard let publicKey else {
            // не переводится: строка журнала
            log("предустановки выключены: в Info.plist нет открытого ключа линии")
            return
        }
        let now = settings()
        guard now.panel.isManaged else {
            // не переводится: строка журнала
            log("предустановки не применяются: машина в ручном режиме")
            return
        }
        guard let channel = Provisioning.secrets?.updates, let url = channel.presetsURL else {
            // не переводится: строка журнала
            log("предустановки выключены: в провижининге нет канала")
            return
        }
        guard !isFetching else { return }
        isFetching = true

        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        // Пара — та же, что у канала обновлений. Подставляется заголовком, а не
        // через хранилище учётных данных: там она лежит под realm обновлений, и
        // полагаться на совпадение realm ради второй линии значило бы завязать
        // её на чужую настройку.
        let pair = "\(channel.user):\(channel.password)"
        if let encoded = pair.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        // По этим заголовкам панель показывает, кто отстал настолько, что новые
        // поля до него не доезжают. Больше она о машинах не узнаёт ничего.
        request.setValue(now.panel.installationID, forHTTPHeaderField: "X-EliteSIP-Installation")
        request.setValue(Self.appVersion, forHTTPHeaderField: "X-EliteSIP-App")
        request.setValue(String(AppSettings.currentSchemaVersion), forHTTPHeaderField: "X-EliteSIP-Schema")
        request.setValue(String(now.panel.appliedRevision), forHTTPHeaderField: "X-EliteSIP-Revision")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                self?.isFetching = false
                self?.receive(data: data, response: response, error: error, publicKey: publicKey)
            }
        }.resume()
    }

    /// Разбирает ответ канала.
    private func receive(data: Data?, response: URLResponse?, error: Error?,
                         publicKey: Curve25519.Signing.PublicKey) {
        if let error {
            // Нет связи — обычное состояние, а не беда. Уровень строки поэтому
            // тот же, что у прочей рутины.
            // не переводится: строка журнала
            log("предустановки: канал недоступен — \(error.localizedDescription)")
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // не переводится: строка журнала
            log("предустановки: канал ответил \(http.statusCode)")
            return
        }
        guard let data else { return }

        let bundle: PresetBundle
        do {
            bundle = try PresetBundle.verified(data, publicKey: publicKey)
        } catch {
            // Подпись не сошлась — файл отбрасывается целиком и молча не
            // остаётся: подделанный байт обязан быть виден в журнале.
            // не переводится: строка журнала
            log("предустановки ОТБРОШЕНЫ: \(error.localizedDescription)")
            return
        }

        let now = settings()
        guard let entry = bundle.entry(id: now.panel.presetID) else {
            // Себя в файле нет — предустановку могли заархивировать. Машина
            // продолжает жить с тем, что применила раньше.
            // не переводится: строка журнала
            log("предустановки: своей записи в файле нет")
            return
        }
        guard entry.revision > now.panel.appliedRevision else { return }

        applyOrDefer(entry)
    }

    /// Применяет ревизию — или откладывает.
    private func applyOrDefer(_ entry: PresetBundle.Entry) {
        guard !isBlocked() else {
            deferred = entry
            // не переводится: строка журнала
            log("предустановка \(entry.revision) ждёт: разговор или открытое «Управление»")
            return
        }
        deferred = nil

        var updated = settings()
        updated.apply(ManagedFields.parse(entry.fields))
        updated.panel.presetName = entry.name
        updated.panel.appliedRevision = entry.revision
        updated.panel.appliedAt = Date()

        // не переводится: строка журнала
        apply(updated, "предустановка «\(entry.name)», ревизия \(entry.revision)")
        log("предустановка применена: «\(entry.name)», ревизия \(entry.revision)")
    }

    /// Помеха ушла — доложить отложенное.
    ///
    /// Зовётся тем же наблюдателем за линиями, что убирает и возвращает
    /// предложение обновиться, и закрытием «Управления».
    func hostBecameIdle() {
        guard let entry = deferred else { return }
        applyOrDefer(entry)
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }
}
