import SwiftUI

/// Лист состояний: все виды панели рядом на одном экране.
///
/// Панели выровнены по нижнему краю не ради красоты — так видно главное
/// обещание компоновки: нижняя полоса стоит на одной линии во всех состояниях,
/// включая те, что раньше её сдвигали.
struct SheetView: View {

    /// Состояния подобраны под то, что в этой правке новое: голова панели.
    ///
    /// Первые четыре — один и тот же покой с разным содержимым слота беды:
    /// именно они отвечают на вопрос, не двигает ли надпись список и
    /// шестерёнку. Последние два оставлены как контроль: голова поменялась, а
    /// обещание про неподвижный низ — нет.
    private let states: [(String, PrototypeState)] = [
        ("Покой · на линии", .make { _ in }),
        ("Нет сети", .make { $0.trouble = .noNetwork }),
        ("Профиль без пароля\n(ведёт в настройки)", .make { $0.trouble = .needsSetup }),
        ("Сервер отказал —\nсамая длинная надпись", .make { $0.trouble = .failed }),
        ("Отключён вручную", .make { $0.isOfflineByChoice = true }),
        ("Разговор", .make {
            $0.phase = .active
            $0.callSeconds = 143
            $0.activeProfileIndex = 2
        }),
    ]

    /// Лист рисуется и в тёмной теме, и в светлой: читаемость мелкого текста
    /// проверяется именно на светлом фоне, где серое по серому исчезает первым.
    private var isLight: Bool { CommandLine.arguments.contains("--light") }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: isLight
                    ? [Color(red: 0.86, green: 0.88, blue: 0.92),
                       Color(red: 0.93, green: 0.90, blue: 0.94)]
                    : [Color(red: 0.15, green: 0.18, blue: 0.25),
                       Color(red: 0.28, green: 0.22, blue: 0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 18) {
                Text("EliteSIP · панель, предложенная компоновка")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isLight ? .black.opacity(0.7) : .white.opacity(0.85))

                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(states.indices, id: \.self) { index in
                        VStack(spacing: 8) {
                            PanelView()
                                .environmentObject(states[index].1)
                                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

                            Text(states[index].0)
                                .font(.system(size: 11))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(isLight ? .black.opacity(0.6) : .white.opacity(0.7))
                                .frame(height: 30, alignment: .top)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

extension PrototypeState {

    /// Отдельное состояние на каждую панель листа: они показываются
    /// одновременно и не должны делить одни и те же поля.
    @MainActor
    static func make(_ configure: (PrototypeState) -> Void) -> PrototypeState {
        let state = PrototypeState(isInteractive: false)
        // `onAppear` в офскрин-рендере не срабатывает, поэтому тему листа
        // выбираем прямо здесь.
        state.isDark = !CommandLine.arguments.contains("--light")
        // Стекло вне окна не рисуется — рисовать его на листе значит показать
        // не ту поверхность, которую обсуждаем. Прозрачность смотрят в
        // `--panel`, лист отвечает только за компоновку.
        state.glass = .material
        configure(state)
        return state
    }
}
