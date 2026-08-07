import SIPCore
import SwiftUI

/// Карточка профиля: отметка активного, название, кому и куда, правка и удаление.
///
/// Карточка, а не строка во всю ширину: на широком окне строка из трёх слов,
/// растянутая на девятьсот точек, — это девятьсот точек пустоты между названием
/// и корзиной. Карточки встают в два столбца по тому же порогу, что и остальные
/// списки окна.
///
/// **Нажатие в любое место карточки переключает профиль.** Это главное действие
/// списка, и требовать попасть в отметку размером 13 точек значило бы сделать
/// его самым трудным. Переименование поэтому спрятано за карандашом: карточка,
/// которая одновременно и кнопка, и поле ввода, не годится ни на то, ни на
/// другое, а править название нужно куда реже, чем переключаться.
struct ProfileCard: View {

    @EnvironmentObject private var model: AppModel
    let profile: SIPProfile

    private var isActive: Bool { profile.id == model.activeProfileID }

    /// Правится ли название прямо сейчас. Своё у каждой карточки: два поля
    /// одновременно не нужны, а гасить чужое пришлось бы отдельным состоянием
    /// на весь список.
    @State private var isEditingLabel = false

    /// Спрошено ли про удаление. Своё у каждой карточки, как и правка названия.
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            header
            details
        }
        .padding(Theme.Metrics.sectionSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedControlSurface(cornerRadius: Theme.Radius.control)
        // Вопрос задаётся здесь, хотя записи удалит только «Сохранить».
        //
        // Решает человек в момент нажатия на корзину, и число он должен видеть
        // тогда же: узнать о потере ста записей после того, как она случилась,
        // — это не предупреждение, а отчёт. Само удаление откладывается до
        // «Сохранить» вместе со всеми правками окна, но «Отменить» историю уже
        // не вернёт, и об этом сказано прямо.
        .alert(isPresented: $isConfirmingRemoval) {
            Alert(
                title: Text("Удалить профиль «\(profile.title)»?"),
                message: Text(removalWarning),
                primaryButton: .destructive(Text("Удалить")) {
                    Task { await model.removeProfile(profile.id) }
                },
                secondaryButton: .cancel(Text("Отмена"))
            )
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            Button {
                Task { await model.selectProfile(profile.id) }
            } label: {
                HStack(spacing: Theme.Metrics.elementSpacing) {
                    // Отметка занимает место и когда её нет: иначе карточки
                    // разъезжаются по горизонтали при смене активного профиля.
                    // Пустого кружка в комплекте иконок для Catalina нет, а
                    // заводить его ради одной строки незачем.
                    if isActive {
                        CompatSymbol(name: "checkmark.circle")
                            .compatForeground(Theme.Palette.registered)
                    } else {
                        Color.clear.frame(width: 13, height: 13)
                    }

                    if isEditingLabel {
                        // `labelsHidden` обязателен: без него первый строковый
                        // аргумент `TextField` становится подписью, и
                        // placeholder уезжает от своего же поля через всю
                        // карточку. Это уже было один раз и выглядело как два
                        // разных поля.
                        TextField("Без названия", text: Binding(
                            get: { profile.label },
                            set: { model.renameProfile(profile.id, to: $0) }
                        ))
                        .labelsHidden()
                    } else {
                        Text(profile.title.isEmpty ? "Новый профиль" : profile.title)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Активная карточка не гасится никогда: серый текст читается как
            // «профиль недоступен», а это ровно тот, на котором работают.
            // Нажатие на неё и так ничего не делает.
            .disabled(!isActive && !model.canSwitchProfile)

            Button {
                isEditingLabel.toggle()
            } label: {
                CompatSymbol(name: isEditingLabel ? "checkmark.circle" : "pencil")
            }
            .buttonStyle(.borderless)
            .compatForeground(Theme.Palette.textSecondary)
            .compatHelp(isEditingLabel ? "Готово" : "Переименовать профиль")

            Button {
                isConfirmingRemoval = true
            } label: {
                CompatSymbol(name: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isActive && !model.canSwitchProfile)
            .compatHelp("Удалить профиль вместе с его паролем и историей звонков")
        }
    }

    /// Кому и куда: номер отдельно от метки, иначе два профиля на одной АТС
    /// различимы только по слову, которое кто-то однажды вписал.
    private var details: some View {
        Text(subtitle)
            .font(.footnote)
            .compatForeground(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var subtitle: String {
        let account = profile.account
        let address = account.domain.isEmpty ? "домен не задан" : account.domain
        let number = account.username.isEmpty ? "номер не задан" : account.username
        var line = "\(number) · \(address) · \(account.transport.protocolName)"
        // «Удалённо» — у всех, кто работает снаружи, включая тех, чьё рабочее
        // место определилось по адресу: для читающего список важно, что этот
        // профиль ходит через шлюз, а не то, кто именно так решил. Офисные
        // профили не подписываются вовсе — это обычный случай, и подпись у
        // каждой карточки не сообщала бы ничего.
        // Проверяется настоящий домен, а не подпись `address`: у ненастроенного
        // профиля там стоит «домен не задан», и на внутренний адрес это не
        // похоже — такой профиль подписался бы удалённым.
        if PortKnockPolicy.needsKnocking(serverHost: account.domain, site: profile.site) {
            line += " · удалённо"
        }
        return line
    }

    /// Что именно уйдёт вместе с профилем.
    ///
    /// История считается на месте, а не берётся из окна истории: то показывает
    /// активный профиль, а удаляют обычно не его.
    private var removalWarning: String {
        let records = model.historyCount(ofProfile: profile.id)
        guard records > 0 else {
            return "Вместе с профилем будет удалён его пароль. Истории звонков у этого профиля нет."
        }
        return """
            Вместе с профилем будут удалены его пароль и \(records) \(Self.recordsWord(records)) \
            истории звонков. Вернуть их «Отменой» будет нельзя.
            """
    }

    /// Число записей произносится по-русски: «1 запись», «2 записи»,
    /// «5 записей». Иначе предупреждение о необратимом действии выглядит
    /// небрежно ровно там, где к нему должно быть больше всего доверия.
    private static func recordsWord(_ count: Int) -> String {
        let tail = count % 100
        if (11...14).contains(tail) { return "записей" }
        switch count % 10 {
        case 1: return "запись"
        case 2, 3, 4: return "записи"
        default: return "записей"
        }
    }
}
