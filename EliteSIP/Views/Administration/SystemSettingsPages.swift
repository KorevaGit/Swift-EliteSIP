import SwiftUI

/// Подразделы «Системы» — как вкладки Windows: «Данные», «Доступ», «Сброс».
///
/// «Обновление» отдельной вкладкой не заводится: настроек обновления в
/// «Управлении» на macOS нет — выпуски ведёт Sparkle, а проверка живёт в
/// настройках менеджера.
enum SystemSettingsPage: CaseIterable, Hashable {
    case data, access, maintenance

    var title: String {
        switch self {
        case .data: NSLocalizedString("Данные", comment: "подраздел «Системы»")
        case .access: NSLocalizedString("Доступ", comment: "подраздел «Системы»")
        case .maintenance: NSLocalizedString("Сброс", comment: "подраздел «Системы»")
        }
    }
}

/// «Система» целиком: шапка с подразделами и выбранный подраздел.
struct SystemSettingsPages: View {

    @State private var page: SystemSettingsPage = .data

    var body: some View {
        Picker("", selection: $page) {
            ForEach(SystemSettingsPage.allCases, id: \.self) { item in
                Text(item.title).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 320, alignment: .leading)
        .padding(.bottom, Theme.Metrics.tightSpacing)

        switch page {
        case .data:
            CallHistorySettingsTab()
            DiagnosticsTab()
        case .access:
            AdministrationTab()
        case .maintenance:
            MaintenanceTab()
        }
    }
}
