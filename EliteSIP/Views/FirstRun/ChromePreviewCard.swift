import SwiftUI

/// Выбор оформления картинкой: как панель выглядит со стеклом и без него.
///
/// Тумблер «Без стекла» отвечал на вопрос словами, а вопрос про внешний вид
/// словами не отвечается: человек, впервые открывший приложение, не знает ни
/// того, что такое стекло в macOS 26, ни того, чем матовая поверхность от него
/// отличается. Две картинки рядом показывают это за секунду — и показывают на
/// том, что он увидит следующим, на панели софтфона.
///
/// **Пример нарисован, а не снят.** Снимок пришлось бы делать в двух темах и
/// пересниматься при каждой правке панели; нарисованная миниатюра берёт цвета из
/// той же палитры, что и настоящая панель, и остаётся резкой на любом мониторе.
/// Точности здесь и не нужно: миниатюра отвечает на «мутное или матовое», а не
/// показывает панель поштучно.
struct ChromePreviewCard: View {

    /// Стеклянный вариант или матовый.
    let isGlass: Bool
    let isSelected: Bool
    /// Есть ли из чего выбирать. Стекло ниже macOS 26 недоступно.
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Metrics.elementSpacing) {
                preview
                    .frame(
                        width: Theme.Metrics.chromePreviewWidth,
                        height: Theme.Metrics.chromePreviewHeight
                    )
                    .compatBackground(alignment: .center) { backdrop }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.surface))
                    .compatOverlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.surface)
                            .stroke(
                                isSelected ? Color.accentColor : Theme.Palette.textTertiary,
                                lineWidth: isSelected ? 2 : 1
                            )
                    }

                Text(isGlass ? "Стекло" : "Без стекла")
                    .font(Theme.Text.controlLabel)

                // Требование системы стоит под самим выбором, а не общей
                // сноской внизу экрана: человек читает подпись того, на что
                // смотрит, и «почему серое» должно найтись там же.
                Text(isGlass ? "Требуется macOS 26" : "Матовые поверхности")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // Выключенная карточка гаснет целиком, вместе с подписью: серая картинка
        // с обычной подписью читается как «картинка не загрузилась».
        .opacity(isEnabled ? 1 : Theme.Metrics.disabledOpacity)
    }

    /// Фон под миниатюрой — то, поверх чего стоит панель на рабочем месте.
    ///
    /// У стекла он виден сквозь поверхность, у матового варианта нет, и это вся
    /// разница, которую миниатюра обязана показать. Поэтому фон один и тот же —
    /// иначе сравнивались бы обои, а не оформление.
    private var backdrop: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.55),
                Color.purple.opacity(0.45),
                Color.orange.opacity(0.35),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Миниатюра панели — по ярусам настоящего экрана вызова.
    ///
    /// Ярусы те же и в том же порядке, что в `PhonePanelView`: строка состояния с
    /// точкой, поле номера, ряд управления, сетка макросов и неподвижный низ с
    /// широкой зелёной кнопкой и «Историей» рядом. Абстрактные полоски, стоявшие
    /// здесь до 17 августа 2026, отвечали на «мутное или матовое», но не давали
    /// узнать в картинке то окно, которое человек увидит следующим.
    ///
    /// Подписей нет намеренно: в миниатюре 90 точек шириной текст превратился бы
    /// в грязь, а формы ярусов узнаются и без него.
    private var preview: some View {
        VStack(spacing: 3) {
            // Строка состояния: зелёная точка и метка профиля.
            HStack(spacing: 2) {
                Circle()
                    .fill(Theme.Palette.answer)
                    .frame(width: 3, height: 3)
                bar(width: 0.5, height: 3)
                Spacer(minLength: 0)
            }

            // Поле номера — самое светлое место панели.
            RoundedRectangle(cornerRadius: 2)
                .fill(fieldFill)
                .frame(height: 13)

            // Ряд управления: три равные клавиши.
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(controlFill)
                        .frame(height: 9)
                }
            }

            // Сетка макросов: три крупные клетки, как у «Юрист · Саммер Бэй · ОП».
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(controlFill)
                        .frame(height: 20)
                }
            }

            Spacer(minLength: 0)

            // Неподвижный низ: широкая «Позвонить» и «История» рядом.
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.Palette.answer.opacity(0.85))
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: 2)
                    .fill(controlFill)
                    .frame(width: 14, height: 14)
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compatBackground(alignment: .center) { surface }
        .padding(8)
    }

    /// Поле номера: под стеклом светлее самой поверхности, без стекла — темнее.
    private var fieldFill: Color {
        isGlass ? Color.white.opacity(0.28) : Theme.Palette.textSecondary.opacity(0.22)
    }

    /// Клавиши и клетки макросов.
    private var controlFill: Color {
        isGlass ? Color.white.opacity(0.42) : Theme.Palette.textSecondary.opacity(0.42)
    }

    /// Сама поверхность панели — единственное, что различается.
    ///
    /// Стекло: полупрозрачная плёнка, сквозь которую виден фон. Матовый вариант:
    /// плотная подложка с чёткой границей, как `NSVisualEffectView` на системах
    /// до macOS 26.
    @ViewBuilder
    private var surface: some View {
        if isGlass {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Color.white.opacity(0.14))
                .compatOverlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                }
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.97))
                .compatOverlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .stroke(Theme.Palette.textTertiary, lineWidth: 0.5)
                }
        }
    }

    /// Полоска подписи: метка профиля в строке состояния.
    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(
                isGlass
                    ? Color.white.opacity(0.55)
                    : Theme.Palette.textSecondary.opacity(0.55)
            )
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .scaleEffect(x: width, y: 1, anchor: .leading)
    }
}
