import Foundation

// MARK: - Разовый сброс при переходе на Spark

/// **Появился в 0.1.43 и живёт, пока на парке могут остаться машины на
/// 0.1.42 и раньше.** Sparkle отдаёт только последнюю сборку: машина,
/// пропустившая 0.1.43 (ноутбук пролежал выключенным), встанет сразу на
/// текущую и без этого сброса осталась бы на ключе EliteSupport. Сброшенные
/// машины несут отметку и второй раз не сбрасываются. Убирать — когда в
/// журнале канала (`X-EliteSIP-App`) не останется версий ниже 0.1.43.
///
/// С 25 сентября 2026 ключи рабочих мест выпускает не панель EliteSupport, а
/// Spark: ключ выписывается на пользователя Битрикса, а файл предустановок
/// подписывается новым ключом (`ESPresetsPublicKey` в `Info.plist` сменён).
/// Прежние активации не переносятся, и машина, поднятая ключом EliteSupport,
/// с новой сборкой не примет ни предустановок, ни пароля настроек, ни отзыва —
/// то есть осталась бы работать на чужом добавочном, вне управления.
///
/// Подписанного отзыва таким машинам выложить нечем: они проверяют его прежним
/// ключом. Поэтому сброс делает сама сборка — один раз, при первом запуске
/// после обновления, тем же путём, что и «Сбросить машину» в «Обслуживании».
/// После сброса машина требует мастер и поднимается ключом из Spark.
///
/// Один раз — по отметке рядом с файлом настроек. Сброс её не уносит (он
/// стирает только свои файлы), поэтому машина, поднятая ключом Spark уже на
/// этой сборке, второй раз не сбросится. Свежая установка отметку просто
/// ставит: сбрасывать в ней нечего.
///
/// Цена порядка выпуска: машина, которую успели поднять ключом Spark ещё на
/// старой сборке, будет сброшена вместе со всеми. Поэтому ключи в Spark
/// выпускаются после того, как машины обновятся до этой сборки.
extension AppModel {

    private static var sparkMigrationMarkerURL: URL {
        SettingsStore.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("spark-migration-reset.done")
    }

    /// Вторая отметка, в `UserDefaults`, — на случай, если файл не записался.
    ///
    /// Одной файловой отметки мало: не ляжет она (права, полный диск) — и
    /// машину, поднятую заново ключом Spark, этот сброс стирал бы на каждом
    /// запуске, вместе с журналом, по которому причину и искали бы. Хранилище
    /// другое, поэтому отказ одного не отменяет другое.
    private static let sparkMigrationDefaultsKey = "SparkMigrationResetDone"

    private static var isSparkMigrationDone: Bool {
        FileManager.default.fileExists(atPath: sparkMigrationMarkerURL.path)
            || UserDefaults.standard.bool(forKey: sparkMigrationDefaultsKey)
    }

    /// Сбрасывает машину, если это первый запуск сборки на уже настроенной
    /// машине. Зовётся при запуске до выбора между мастером и панелью.
    func performSparkMigrationResetIfNeeded() {
        let marker = Self.sparkMigrationMarkerURL
        guard !Self.isSparkMigrationDone else { return }

        let wasConfigured = firstRun == .passed
        if wasConfigured {
            append(level: .warning,
                   message: "переход на ключи Spark: машина, поднятая ключом EliteSupport, сбрасывается один раз")
            resetMachine()
        }

        // Отметка — после сброса: упади он посередине, следующий запуск
        // повторит его, а не оставит машину наполовину стёртой без попытки.
        UserDefaults.standard.set(true, forKey: Self.sparkMigrationDefaultsKey)
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(Date())\n".utf8).write(to: marker, options: .atomic)
        } catch {
            append(level: .warning, message: "отметка о переходе на Spark не записана: \(error.localizedDescription)")
        }
    }
}
