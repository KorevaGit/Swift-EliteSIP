package preset

import (
	"crypto/rand"
	"fmt"
	"strings"
)

// Пределы взяты из приложения, а не придуманы здесь. Ссылки на источник — в
// комментариях: разойтись с ними значит выпустить ревизию, которую машина
// приведёт к своим границам молча, и панель будет показывать не то, что стоит
// на местах.
const (
	// maximumMacros — DTMFSettings.maximumMacros. Высота панели выведена из
	// числа клавиш и обязана оставаться константой установки.
	maximumMacros = 18

	// columnRange и heightRange — DTMFSettings.columnRange и .heightRange.
	minColumns = 1
	maxColumns = 4
	minHeight  = 44
	maxHeight  = 96

	// Длительности тонов приложением не ограничены, поэтому границы здесь свои
	// и широкие: они ловят опечатку в разряде (12 вместо 120), а не спорят с
	// администратором о вкусе.
	minMilliseconds = 20
	maxMilliseconds = 2000

	// maxTargetCount — сколько кнопок-целей показывать. Единица означает
	// обычную кнопку «Ответить»; больше девяти на окне не разместить.
	maxTargetCount = 9
)

// dtmfCharacters — что допускает DTMFSequence: цифры, звёздочка, решётка,
// A–D и запятая как пауза.
const dtmfCharacters = "0123456789*#ABCD,"

// Validate проверяет поля перед сохранением ревизии.
//
// Проверка строгая, и вот почему: сохранённая ревизия уезжает на все рабочие
// места за полчаса и применяется обязательно, без возможности отложить. Это
// единственное место, где опечатку ещё можно показать человеку.
//
// Ошибки возвращаются все сразу, а не первая: форма на сайте должна показать
// разом всё, что не так, иначе администратор чинит её по одной за проход.
func (f Fields) Validate() []error {
	var problems []error

	if f.DTMF != nil {
		problems = append(problems, f.DTMF.validate()...)
	}
	if f.IncomingCall != nil {
		problems = append(problems, f.IncomingCall.validate()...)
	}
	if f.Queues != nil {
		problems = append(problems, f.Queues.validate()...)
	}
	if f.Conference != nil {
		problems = append(problems, f.Conference.validate()...)
	}
	if f.SiteAddress != nil {
		problems = append(problems, f.SiteAddress.validate()...)
	}
	if f.PortKnock != nil {
		problems = append(problems, f.PortKnock.validate()...)
	}
	return problems
}

func (d DTMF) validate() []error {
	var problems []error

	for name, value := range map[string]int{
		"длительность тона": d.ToneMilliseconds,
		"промежуток":        d.GapMilliseconds,
		"пауза":             d.PauseMilliseconds,
	} {
		if value < minMilliseconds || value > maxMilliseconds {
			problems = append(problems, fmt.Errorf(
				"%s: %d мс вне пределов %d–%d", name, value, minMilliseconds, maxMilliseconds))
		}
	}

	if d.MacroColumns < minColumns || d.MacroColumns > maxColumns {
		problems = append(problems, fmt.Errorf(
			"клавиш в ряду: %d вне пределов %d–%d", d.MacroColumns, minColumns, maxColumns))
	}
	if d.MacroHeight < minHeight || d.MacroHeight > maxHeight {
		problems = append(problems, fmt.Errorf(
			"высота клавиши: %d вне пределов %d–%d", d.MacroHeight, minHeight, maxHeight))
	}
	if len(d.Macros) > maximumMacros {
		problems = append(problems, fmt.Errorf(
			"клавиш %d, а больше %d панель не вмещает", len(d.Macros), maximumMacros))
	}

	seen := map[string]bool{}
	for i, m := range d.Macros {
		where := fmt.Sprintf("клавиша %d", i+1)
		if strings.TrimSpace(m.Title) == "" {
			problems = append(problems, fmt.Errorf("%s: пустая подпись", where))
		}
		if err := validateSequence(where, m.Sequence); err != nil {
			problems = append(problems, err)
		}
		if err := validateID(where, m.ID); err != nil {
			problems = append(problems, err)
		}
		if seen[m.ID] {
			problems = append(problems, fmt.Errorf("%s: повторяющийся идентификатор %s", where, m.ID))
		}
		seen[m.ID] = true
	}
	return problems
}

func (c CallGuard) validate() []error {
	var problems []error

	if c.TargetCount < 1 || c.TargetCount > maxTargetCount {
		problems = append(problems, fmt.Errorf(
			"кнопок-целей: %d вне пределов 1–%d", c.TargetCount, maxTargetCount))
	}
	if c.MinimumTravel < 0 {
		problems = append(problems, fmt.Errorf("смещение окна отрицательное: %g", c.MinimumTravel))
	}
	if c.ScreenMargin < 0 {
		problems = append(problems, fmt.Errorf("отступ от краёв отрицательный: %g", c.ScreenMargin))
	}
	if c.RequiredCursorTravel < 0 {
		problems = append(problems, fmt.Errorf("путь курсора отрицательный: %g", c.RequiredCursorTravel))
	}

	// Требование движения курсора с нулевым порогом — это выключенная защита,
	// которая выглядит включённой. Хуже честно выключенной: в панели галочка
	// стоит, а не ловит ничего.
	if c.RequiresCursorMovement {
		if c.RequiredCursorTravel <= 0 {
			problems = append(problems, fmt.Errorf(
				"движение курсора требуется, но путь нулевой — защита выглядит включённой и не работает"))
		}
		if c.RequiredCursorSamples < 2 {
			problems = append(problems, fmt.Errorf(
				"движение курсора требуется, но перемещений нужно %d — одно это прыжок",
				c.RequiredCursorSamples))
		}
	}
	return problems
}

func (q Queues) validate() []error {
	var problems []error

	seenNumber := map[string]int{}
	seenID := map[string]bool{}

	for i, item := range q.Queues {
		where := fmt.Sprintf("очередь %d", i+1)

		digits := normalizeQueueNumber(item.Number)
		if digits == "" {
			problems = append(problems, fmt.Errorf("%s: пустой номер", where))
		}
		if strings.TrimSpace(item.Title) == "" {
			// Половина записи хуже её отсутствия: номер без названия убрал бы
			// номер из окна входящего и не дал взамен ничего.
			problems = append(problems, fmt.Errorf("%s: пустое название", where))
		}
		if first, ok := seenNumber[digits]; ok && digits != "" {
			problems = append(problems, fmt.Errorf(
				"%s: номер %s уже занят очередью %d", where, item.Number, first))
		} else if digits != "" {
			seenNumber[digits] = i + 1
		}

		if err := validateID(where, item.ID); err != nil {
			problems = append(problems, err)
		}
		if seenID[item.ID] {
			problems = append(problems, fmt.Errorf("%s: повторяющийся идентификатор %s", where, item.ID))
		}
		seenID[item.ID] = true
	}
	return problems
}

func (c Conference) validate() []error {
	var problems []error

	if err := validateSequence("код конференции", c.FeatureCode); err != nil {
		problems = append(problems, err)
	}
	if strings.TrimSpace(c.FeatureCode) == "" {
		problems = append(problems, fmt.Errorf("код конференции пуст — собрать конференцию будет нечем"))
	}
	if strings.TrimSpace(c.RoomExtension) == "" {
		problems = append(problems, fmt.Errorf("добавочный комнаты пуст"))
	}
	return problems
}

func (s SiteAddresses) validate() []error {
	var problems []error

	for name, value := range map[string]string{
		"адрес АТС изнутри": s.Office,
		"адрес АТС снаружи": s.Remote,
	} {
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			problems = append(problems, fmt.Errorf("%s пуст", name))
			continue
		}
		if trimmed != value || strings.ContainsAny(value, " \t/") {
			problems = append(problems, fmt.Errorf("%s содержит лишние знаки: %q", name, value))
		}
	}

	// Один адрес на оба места означает, что переключатель «офис ↔ дом» ничего
	// не переключает. Это почти всегда недозаполненная форма, а не замысел.
	if s.Office != "" && s.Office == s.Remote {
		problems = append(problems, fmt.Errorf(
			"адреса изнутри и снаружи совпадают — переключение рабочего места перестанет что-либо менять"))
	}
	return problems
}

func (p PortKnock) validate() []error {
	var problems []error

	// Пустой список — это «стучать нечем», и он допустим: так стук выключают.
	for i, step := range p.Steps {
		where := fmt.Sprintf("шаг стука %d", i+1)
		if step.PayloadBytes < 1 || step.PayloadBytes > 65500 {
			problems = append(problems, fmt.Errorf(
				"%s: размер пакета %d вне пределов 1–65500", where, step.PayloadBytes))
		}
		if step.Count < 1 || step.Count > 10 {
			problems = append(problems, fmt.Errorf(
				"%s: пакетов %d вне пределов 1–10", where, step.Count))
		}
		if step.Host != "" && strings.ContainsAny(step.Host, " \t/") {
			problems = append(problems, fmt.Errorf("%s: адрес содержит лишние знаки: %q", where, step.Host))
		}
	}

	if p.SpacingSeconds < 0.1 || p.SpacingSeconds > 10 {
		problems = append(problems, fmt.Errorf(
			"промежуток между пакетами %g с вне пределов 0,1–10", p.SpacingSeconds))
	}
	// Ниже минуты стук превращается в постоянный поток ICMP с полусотни
	// рабочих мест, выше часа — перестаёт держать доступ открытым.
	if p.RepeatIntervalSeconds < 60 || p.RepeatIntervalSeconds > 3600 {
		problems = append(problems, fmt.Errorf(
			"повтор стука %g с вне пределов 60–3600", p.RepeatIntervalSeconds))
	}
	return problems
}

func validateSequence(where, sequence string) error {
	for _, r := range strings.ToUpper(sequence) {
		if !strings.ContainsRune(dtmfCharacters, r) {
			return fmt.Errorf("%s: знак %q не набирается тоном", where, r)
		}
	}
	return nil
}

func normalizeQueueNumber(number string) string {
	var b strings.Builder
	for _, r := range number {
		if (r >= '0' && r <= '9') || r == '*' || r == '#' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func validateID(where, id string) error {
	if len(id) != 36 {
		return fmt.Errorf("%s: идентификатор не похож на UUID: %q", where, id)
	}
	for i, r := range id {
		switch i {
		case 8, 13, 18, 23:
			if r != '-' {
				return fmt.Errorf("%s: идентификатор не похож на UUID: %q", where, id)
			}
		default:
			isHex := (r >= '0' && r <= '9') || (r >= 'A' && r <= 'F') || (r >= 'a' && r <= 'f')
			if !isHex {
				return fmt.Errorf("%s: идентификатор не похож на UUID: %q", where, id)
			}
		}
	}
	return nil
}

// NewID выпускает идентификатор для клавиши или очереди.
//
// UUID версии 4 в верхнем регистре — в том же виде, в каком его пишет Swift:
// эти строки лежат в файле настроек рядом с теми, что завёл администратор на
// машине, и различаться по виду им незачем.
func NewID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("случайные байты для идентификатора: %w", err)
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80

	const hexDigits = "0123456789ABCDEF"
	out := make([]byte, 0, 36)
	for i, b := range raw {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out = append(out, '-')
		}
		out = append(out, hexDigits[b>>4], hexDigits[b&0x0f])
	}
	return string(out), nil
}
