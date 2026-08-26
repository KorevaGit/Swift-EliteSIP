package preset

import (
	"fmt"
	"strconv"
)

// Changes перечисляет словами, что меняется между двумя ревизиями.
//
// Словами, а не техническим диффом: список читает техподдержка заказчика перед
// тем, как правка уедет на все рабочие места обязательным обновлением, которое
// сотрудник не может отложить. Технический дифф в этот момент пролистывают не
// читая, и смысл проверки пропадает.
//
// Это тот самый пункт, который в приложении записан невыполненным долгом M8 —
// «применить неизвестно что на чужом рабочем месте недопустимо». Здесь он
// стоит дёшево, потому что обе ревизии лежат в базе целиком.
//
// Пустой ответ означает «ничего не меняется», и это тоже полезное знание:
// выкладка без изменений — обычно признак, что правку не сохранили.
func Changes(before, after Fields) []string {
	var out []string

	out = append(out, dtmfChanges(before.DTMF, after.DTMF)...)
	out = append(out, macroChanges(before.DTMF, after.DTMF)...)
	out = append(out, queueChanges(before.Queues, after.Queues)...)
	out = append(out, conferenceChanges(before.Conference, after.Conference)...)
	out = append(out, addressChanges(before.SiteAddress, after.SiteAddress)...)
	out = append(out, knockChanges(before.PortKnock, after.PortKnock)...)
	out = append(out, guardChanges(before.IncomingCall, after.IncomingCall)...)
	out = append(out, trustChanges(before.AcceptsAnyTLSCertificate, after.AcceptsAnyTLSCertificate)...)

	return out
}

// ------------------------------------------------------------------ клавиши

func dtmfChanges(before, after *DTMF) []string {
	if before == nil || after == nil {
		return managedChange("Тоны и раскладка клавиш", before == nil, after == nil)
	}

	var out []string
	out = appendInt(out, "Длительность тона", before.ToneMilliseconds, after.ToneMilliseconds, " мс")
	out = appendInt(out, "Промежуток между тонами", before.GapMilliseconds, after.GapMilliseconds, " мс")
	out = appendInt(out, "Пауза (запятая)", before.PauseMilliseconds, after.PauseMilliseconds, " мс")
	out = appendInt(out, "Клавиш в ряду", before.MacroColumns, after.MacroColumns, "")
	out = appendInt(out, "Высота клавиши", before.MacroHeight, after.MacroHeight, " точек")
	out = appendBool(out, "Высоту клавиши задаёт человек",
		before.MacroHeightIsManual, after.MacroHeightIsManual)
	return out
}

// macroChanges сличает клавиши по идентификатору, а не по месту в списке.
//
// По месту вставка строки в середину показала бы изменившимися все клавиши
// ниже — и человек, которому список нужен ровно затем, чтобы заметить лишнее,
// перестал бы его читать.
func macroChanges(before, after *DTMF) []string {
	if before == nil || after == nil {
		return nil
	}

	was := map[string]Macro{}
	for _, m := range before.Macros {
		was[m.ID] = m
	}
	seen := map[string]bool{}

	var out []string
	for _, m := range after.Macros {
		seen[m.ID] = true
		old, existed := was[m.ID]
		if !existed {
			out = append(out, fmt.Sprintf("Клавиша «%s» добавлена: набор %s", m.Title, quote(m.Sequence)))
			continue
		}
		if old.Title != m.Title {
			out = append(out, fmt.Sprintf("Клавиша «%s» переименована в «%s»", old.Title, m.Title))
		}
		if old.Sequence != m.Sequence {
			out = append(out, fmt.Sprintf("Клавиша «%s»: набор %s → %s",
				m.Title, quote(old.Sequence), quote(m.Sequence)))
		}
		if old.TransfersCall != m.TransfersCall {
			mark := "перестала помечаться как перевод звонка"
			if m.TransfersCall {
				mark = "теперь помечается как перевод звонка"
			}
			out = append(out, fmt.Sprintf("Клавиша «%s» %s", m.Title, mark))
		}
	}
	for _, m := range before.Macros {
		if !seen[m.ID] {
			out = append(out, fmt.Sprintf("Клавиша «%s» удалена", m.Title))
		}
	}
	return out
}

// ------------------------------------------------------------------ очереди

func queueChanges(before, after *Queues) []string {
	if before == nil || after == nil {
		return managedChange("Очереди", before == nil, after == nil)
	}

	was := map[string]Queue{}
	for _, q := range before.Queues {
		was[q.ID] = q
	}
	seen := map[string]bool{}

	var out []string
	for _, q := range after.Queues {
		seen[q.ID] = true
		old, existed := was[q.ID]
		if !existed {
			out = append(out, fmt.Sprintf("Очередь «%s» добавлена: номер %s", q.Title, q.Number))
			continue
		}
		if old.Number != q.Number {
			out = append(out, fmt.Sprintf("Очередь «%s»: номер %s → %s", q.Title, old.Number, q.Number))
		}
		if old.Title != q.Title {
			out = append(out, fmt.Sprintf("Очередь %s переименована: «%s» → «%s»", q.Number, old.Title, q.Title))
		}
	}
	for _, q := range before.Queues {
		if !seen[q.ID] {
			out = append(out, fmt.Sprintf("Очередь «%s» (%s) удалена", q.Title, q.Number))
		}
	}
	return out
}

// -------------------------------------------------------------- конференция

func conferenceChanges(before, after *Conference) []string {
	if before == nil || after == nil {
		return managedChange("Конференция", before == nil, after == nil)
	}

	var out []string
	out = appendText(out, "Код конференции", before.FeatureCode, after.FeatureCode)
	out = appendText(out, "Добавочный комнаты конференции", before.RoomExtension, after.RoomExtension)
	return out
}

// ------------------------------------------------------------------ адреса

// addressChanges — самое опасное, что возит эта линия: разъехавшийся адрес
// означает телефон, который не звонит на всех рабочих местах разом.
func addressChanges(before, after *SiteAddresses) []string {
	if before == nil || after == nil {
		return managedChange("Адреса АТС", before == nil, after == nil)
	}

	var out []string
	out = appendText(out, "Адрес АТС изнутри", before.Office, after.Office)
	out = appendText(out, "Адрес АТС снаружи", before.Remote, after.Remote)
	return out
}

// -------------------------------------------------------------------- стук

// knockChanges о шагах говорит целиком, а не построчно.
//
// У шага нет ни имени, ни идентификатора — только адрес, байты и счётчик, — и
// «шаг 3 изменился» человеку ничего не сообщает. Последовательность стука
// читают как одно целое, ею она и показывается.
func knockChanges(before, after *PortKnock) []string {
	if before == nil || after == nil {
		return managedChange("Стук", before == nil, after == nil)
	}

	var out []string
	out = appendFloat(out, "Промежуток между шагами стука",
		before.SpacingSeconds, after.SpacingSeconds, " с")
	out = appendFloat(out, "Повтор стука",
		before.RepeatIntervalSeconds, after.RepeatIntervalSeconds, " с")

	if !sameSteps(before.Steps, after.Steps) {
		out = append(out, fmt.Sprintf("Последовательность стука изменена: было %d %s, стало %d",
			len(before.Steps), pluralStep(len(before.Steps)), len(after.Steps)))
	}
	return out
}

func sameSteps(before, after []KnockStep) bool {
	if len(before) != len(after) {
		return false
	}
	for i := range before {
		if before[i] != after[i] {
			return false
		}
	}
	return true
}

func pluralStep(n int) string {
	switch {
	case n%100 >= 11 && n%100 <= 14:
		return "шагов"
	case n%10 == 1:
		return "шаг"
	case n%10 >= 2 && n%10 <= 4:
		return "шага"
	default:
		return "шагов"
	}
}

// ------------------------------------------------------------------ защита

func guardChanges(before, after *CallGuard) []string {
	if before == nil || after == nil {
		return managedChange("Защита от автокликеров", before == nil, after == nil)
	}

	var out []string
	out = appendBool(out, "Защита от автокликеров", before.IsEnabled, after.IsEnabled)
	out = appendBool(out, "Случайное место кнопки",
		before.IsRandomPositionEnabled, after.IsRandomPositionEnabled)
	out = appendBool(out, "Разброс настраивается вручную",
		before.TunesRandomnessByHand, after.TunesRandomnessByHand)
	out = appendFloat(out, "Наименьший сдвиг кнопки", before.MinimumTravel, after.MinimumTravel, " точек")
	out = appendFloat(out, "Отступ от края экрана", before.ScreenMargin, after.ScreenMargin, " точек")
	out = appendInt(out, "Сколько кнопок показывать", before.TargetCount, after.TargetCount, "")
	out = appendBool(out, "Требовать движение курсора",
		before.RequiresCursorMovement, after.RequiresCursorMovement)
	out = appendBool(out, "Живость настраивается вручную",
		before.TunesLivenessByHand, after.TunesLivenessByHand)
	out = appendFloat(out, "Требуемый путь курсора",
		before.RequiredCursorTravel, after.RequiredCursorTravel, " точек")
	out = appendInt(out, "Требуемое число замеров курсора",
		before.RequiredCursorSamples, after.RequiredCursorSamples, "")
	out = appendBool(out, "Отклонять синтетические события",
		before.RejectsSyntheticEvents, after.RejectsSyntheticEvents)
	return out
}

func trustChanges(before, after *bool) []string {
	if before == nil || after == nil {
		return managedChange("Доверие любому TLS-сертификату", before == nil, after == nil)
	}
	if *before == *after {
		return nil
	}
	if *after {
		// Отдельными словами, потому что это единственное изменение в списке,
		// которое ослабляет защиту: аудит M7b нашёл включённое ради лаборатории
		// значение, молча оставшееся включённым на боевом профиле.
		return []string{"Доверие любому TLS-сертификату ВКЛЮЧЕНО — проверка подлинности АТС отключается"}
	}
	return []string{"Доверие любому TLS-сертификату выключено"}
}

// ------------------------------------------------------------------ помощь

// managedChange описывает появление или уход целого раздела.
//
// Отсутствующий раздел означает «панель им не управляет»: машина сохранит своё
// текущее значение. Разница между «панель перестала управлять» и «значение
// поменялось» существенная, и слить их в одну строку нельзя.
func managedChange(what string, wasAbsent, isAbsent bool) []string {
	switch {
	case wasAbsent && !isAbsent:
		return []string{what + ": панель начинает этим управлять"}
	case !wasAbsent && isAbsent:
		return []string{what + ": панель перестаёт этим управлять — машины сохранят своё текущее"}
	default:
		return nil
	}
}

func appendInt(out []string, what string, before, after int, unit string) []string {
	if before == after {
		return out
	}
	return append(out, fmt.Sprintf("%s: %d%s → %d%s", what, before, unit, after, unit))
}

func appendFloat(out []string, what string, before, after float64, unit string) []string {
	if before == after {
		return out
	}
	return append(out, fmt.Sprintf("%s: %s%s → %s%s",
		what, trimFloat(before), unit, trimFloat(after), unit))
}

func appendText(out []string, what, before, after string) []string {
	if before == after {
		return out
	}
	return append(out, fmt.Sprintf("%s: %s → %s", what, quote(before), quote(after)))
}

func appendBool(out []string, what string, before, after bool) []string {
	if before == after {
		return out
	}
	if after {
		return append(out, what+": включено")
	}
	return append(out, what+": выключено")
}

func quote(s string) string {
	if s == "" {
		return "(пусто)"
	}
	return "«" + s + "»"
}

// trimFloat печатает число без хвостовых нулей: «1 с» вместо «1.000000 с».
func trimFloat(v float64) string {
	return strconv.FormatFloat(v, 'f', -1, 64)
}

// ------------------------------------------------------- опасное и обычное

// Report — те же изменения, но разделённые по цене ошибки.
//
// Разделение появилось 25 августа 2026 вместе с отменой замка на адресах АТС.
// Прежде опасные поля стерёг замок в форме; теперь форма — отдельный режим, а
// последним рубежом стало окно выкладки, и оно обязано показывать опасное
// отдельно, а не строкой в общем списке из двадцати.
type Report struct {
	// Dangerous — то, из-за чего телефон перестаёт звонить на всех рабочих
	// местах разом: адреса АТС, стук и доверие к сертификату. Показывается
	// всегда целиком и первым.
	Dangerous []string

	// Ordinary — всё остальное: клавиши, очереди, конференция, защита приёма.
	// Ошибка здесь стоит одного неверного набора, а не всей конторы, поэтому
	// список можно сворачивать счётчиком.
	Ordinary []string
}

// Empty — ничего не меняется.
func (r Report) Empty() bool { return len(r.Dangerous) == 0 && len(r.Ordinary) == 0 }

// Count — сколько изменений всего.
func (r Report) Count() int { return len(r.Dangerous) + len(r.Ordinary) }

// Grouped сличает две ревизии и раскладывает изменения по цене ошибки.
func Grouped(before, after Fields) Report {
	var r Report

	r.Dangerous = append(r.Dangerous, addressChanges(before.SiteAddress, after.SiteAddress)...)
	r.Dangerous = append(r.Dangerous, knockChanges(before.PortKnock, after.PortKnock)...)
	r.Dangerous = append(r.Dangerous, trustChanges(
		before.AcceptsAnyTLSCertificate, after.AcceptsAnyTLSCertificate)...)

	r.Ordinary = append(r.Ordinary, dtmfChanges(before.DTMF, after.DTMF)...)
	r.Ordinary = append(r.Ordinary, macroChanges(before.DTMF, after.DTMF)...)
	r.Ordinary = append(r.Ordinary, queueChanges(before.Queues, after.Queues)...)
	r.Ordinary = append(r.Ordinary, conferenceChanges(before.Conference, after.Conference)...)
	r.Ordinary = append(r.Ordinary, guardChanges(before.IncomingCall, after.IncomingCall)...)

	return r
}
