import AppKit
import SIPCore
import SwiftUI

/// Живая трасса SIP отдельным окном.
///
/// До этапа 5 жила внутри вкладки «Диагностика» и занимала больше половины её
/// высоты. Место было неудачным дважды: раздел настроек нельзя растянуть под
/// длинные строки SIP и нельзя оставить открытым, не оставив открытым весь
/// черновик закрытых настроек, — а смотреть трассу нужно ровно во время
/// звонка.
///
/// Инструмент разработчика, а не администратора: тот при разборе жалобы берёт
/// архив. Пока разработчик и администратор — один человек, кнопка стоит в
/// «Диагностике».
struct SIPTraceWindowView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                Text("Показывать от")
                    .font(.callout)

                Picker("", selection: Binding(
                    get: { model.settings.minimumLogLevel },
                    set: { model.settings.minimumLogLevel = $0 }
                )) {
                    ForEach(SIPLogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // По левому краю: иначе между подписью и сегментами появляется
                // пустота, которой нет ни в одной другой строке.
                .frame(maxWidth: 280, alignment: .leading)

                Spacer()

                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
                .disabled(model.log.isEmpty)

                Button("Очистить") { model.clearLog() }
                    .disabled(model.log.isEmpty)
            }

            logView
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.bottom, Theme.Metrics.contentPadding)
        .padding(.top, Theme.Gap.titleToStatus)
        .frame(
            minWidth: Theme.Metrics.traceMinWidth,
            minHeight: Theme.Metrics.traceMinHeight
        )
        .compatBackground {
            Color.clear
                .themedPanelSurface(cornerRadius: 0)
                .compatIgnoreSafeArea()
        }
    }

    /// Ветка по версии здесь не косметическая, а по наличию API:
    /// `ScrollViewReader`, без которого некуда прокручивать, и `LazyVStack`
    /// появились только в macOS 11. На Catalina трасса остаётся обычным списком
    /// без автопрокрутки — 500 строк обычный `VStack` тянет, а к свежей записи
    /// доводят колесом.
    @ViewBuilder
    private var logView: some View {
        if #available(macOS 11.0, *) {
            ScrollViewReader { proxy in
                logScroll(isLazy: true)
                    .onChange(of: model.log.count) { _ in
                        // Прокрутка к свежей строке: без неё трасса бесполезна
                        // ровно в тот момент, когда она нужна.
                        if let last = model.log.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
            }
        } else {
            logScroll(isLazy: false)
        }
    }

    @ViewBuilder
    private func logScroll(isLazy: Bool) -> some View {
        ScrollView {
            Group {
                if isLazy, #available(macOS 11.0, *) {
                    LazyVStack(alignment: .leading, spacing: 2) { logLines }
                } else {
                    VStack(alignment: .leading, spacing: 2) { logLines }
                }
            }
            .padding(Theme.Metrics.sectionSpacing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedControlSurface()
        .compatOverlay {
            if model.log.isEmpty {
                Text("Пусто. Нажмите «Подключить».")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textTertiary)
            }
        }
    }

    private var logLines: some View {
        ForEach(model.log) { entry in
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.sectionSpacing) {
                Text(TimeText.withSeconds.string(from: entry.date))
                    .compatForeground(Theme.Palette.textTertiary)
                Text(entry.message)
                    .compatForeground(color(for: entry.level))
                    .compatTextSelection()
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(entry.id)
        }
    }

    private func color(for level: SIPLogLevel) -> Color {
        switch level {
        case .debug: Theme.Palette.textSecondary
        case .info: Theme.Palette.textPrimary
        case .warning: Theme.Palette.connecting
        case .error: Theme.Palette.failure
        }
    }
}
