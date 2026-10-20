import Foundation
import SIPCore

/// Закреплённый формат работы: Spark запрещает менеджеру переключать
/// «Офис ↔ Из дома» в разделе «Работа».
///
/// **Почему запрет снимается административным паролем, а не только из Spark.**
/// Администратор у машины бывает и тогда, когда до Spark ему не дотянуться, —
/// а ставить менеджера звонить в недостижимый адрес ради чистоты запрета
/// незачем. Но снятие паролем — это правка управляемой настройки на месте, и
/// последствия у неё те же, что у правки в «Управлении»: машина уходит в
/// оффлайн, и Spark ею больше не управляет, пока её не вернут в онлайн.
///
/// **Чего здесь нет.** Запрета вне панели: в оффлайне машиной управляет
/// человек на месте, и запрет уходит вместе с остальными управляемыми полями
/// (`PanelSettings.isWorkFormatLocked`).
extension AppModel {

    /// Площадка, закреплённая Spark, — если закреплена и машина под панелью.
    var lockedWorkplaceSite: SIPProfileSite? {
        guard settings.panel.isWorkFormatLocked else { return nil }
        return siteFor(workFormat: settings.panel.lockedWorkFormat)
    }

    /// Заперт ли переключатель «Работа» для того, кто сидит за машиной.
    /// Открытый административный режим запрет снимает.
    var isWorkplaceSwitchLocked: Bool {
        lockedWorkplaceSite != nil && !allowsAdministration
    }

    /// Заперто ли «Исправить сеть».
    ///
    /// Только при закреплённом офисе: из офиса АТС достижима напрямую, и
    /// стучаться к ней снаружи незачем. Закреплённому дому кнопка остаётся —
    /// иначе человек дома не смог бы сам починить дорогу, когда у домашнего
    /// интернета сменился адрес.
    var isNetworkRepairLocked: Bool {
        isWorkplaceSwitchLocked && lockedWorkplaceSite == .office
    }

    /// Выбор площадки в разделе «Работа».
    ///
    /// Отдельно от `setProfileSite`: та — механика переезда, а здесь решение,
    /// можно ли переезжать и чего это стоит.
    func chooseWorkplaceSite(_ site: SIPProfileSite) async {
        guard site != workplaceSite else { return }
        guard !isWorkplaceSwitchLocked else {
            append(level: .warning, message: "формат работы закреплён в Spark — переключение отклонено")
            return
        }
        // Переключение поверх закрепления — то же, что правка управляемого
        // поля в «Управлении». Связка рвётся до переезда: в разговоре
        // `setProfileSite` откажет, и тогда рвать её не за что.
        if lockedWorkplaceSite != nil {
            guard canSwitchProfile else {
                refuseProfileChange()
                return
            }
            settings.panel.mode = .manual
            settings.panel.wantsResync = false
            settings.incomingCall.isServerManaged = false
            persistSettings()
            append(
                level: .warning,
                message: "оффлайн: закреплённый формат работы сменён по административному паролю"
            )
            ClientEventLog.shared.record(.config, .warning,
                "Закреплённый формат работы сменён на месте по административному паролю — машина в оффлайне")
        }
        await setProfileSite(site, for: settings.profiles.activeID)
    }

    /// Возвращает площадку туда, куда её закрепил Spark.
    ///
    /// Нужна после возврата в онлайн: ревизия конфигурации за время оффлайна
    /// могла не смениться, и тогда площадку, переставленную на месте, не
    /// вернул бы никто. Зовётся там же, где накладывается предустановка, —
    /// не в разговоре и не поверх черновика «Управления».
    func enforceLockedWorkplaceSite() {
        guard let site = lockedWorkplaceSite, site != workplaceSite else { return }
        append(level: .info, message: "площадка возвращена к закреплённой в Spark: \(site.title)")
        Task { [weak self] in
            guard let self else { return }
            await self.setProfileSite(site, for: self.settings.profiles.activeID)
        }
    }
}
