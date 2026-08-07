import SIPCore
import SwiftUI

/// Выбор рабочего места — двумя кнопками.
///
/// Третьего варианта «определять по адресу» на экране нет: человек выбирает
/// руками, и предлагать ему «не выбирать» бессмысленно. Система решает сама и
/// показывает решение выбранным, а нажатие закрепляет его явно — и заодно
/// переносит профиль на нужный адрес АТС.
///
/// Кнопки, а не переключатель, потому что это действие с последствиями:
/// перерегистрация сейчас.
///
/// Не `private`: те же две кнопки стоят на менеджерской странице (M7c). Смена
/// офис ↔ удалёнка — единственное, что менеджер делает с профилем сам, приехав
/// домой, и заводить для этого вторую пару кнопок значило бы однажды их
/// разойтись.
struct WorkplacePicker: View {

    @EnvironmentObject private var model: AppModel

    private var profile: SIPProfile { model.settings.profiles.active }

    /// Что выбрано на самом деле: у профиля, которому место ещё не задавали,
    /// это решение по адресу сервера.
    private var resolved: SIPProfileSite {
        PortKnockPolicy.resolvedSite(serverHost: profile.account.domain, site: profile.site)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                button(.office, title: "Офис", subtitle: model.settings.siteAddresses.office)
                button(.remote, title: "Удалённо", subtitle: model.settings.siteAddresses.remote)
                Spacer()
            }

            if profile.site == .automatic {
                Text("Определено по адресу сервера. Нажмите, чтобы закрепить или сменить.")
                    .font(.footnote)
                    .compatForeground(.secondary)
            }
        }
    }

    @ViewBuilder
    private func button(_ site: SIPProfileSite, title: String, subtitle: String) -> some View {
        let isSelected = resolved == site
        Button {
            Task { await model.setProfileSite(site, for: model.activeProfileID) }
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    // Отметка, а не только стиль кнопки: акцентный стиль
                    // появился в macOS 12, и на Catalina обе кнопки выглядели
                    // бы одинаково — то есть выбранного не было бы видно.
                    if isSelected {
                        CompatSymbol(name: "checkmark.circle")
                            .compatForeground(Theme.Palette.registered)
                    }
                    Text(title)
                }
                Text(subtitle)
                    .font(.footnote)
                    .compatForeground(.secondary)
            }
            .frame(minWidth: 130)
        }
        .compatProminentButtonStyle(isSelected)
        .disabled(!model.canSwitchProfile)
        .compatHelp(
            isSelected && profile.site != .automatic
                ? "Уже выбрано"
                : "Перевести профиль на адрес \(subtitle)"
        )
    }
}
