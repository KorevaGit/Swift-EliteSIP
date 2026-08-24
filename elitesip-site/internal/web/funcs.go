package web

import (
	"fmt"
	"html/template"
	"math"
	"time"
)

var templateFuncs = template.FuncMap{
	"moment":    moment,
	"day":       day,
	"ago":       ago,
	"remaining": remaining,
	"plural":    plural,
	"deref":     deref,
	"hasValue":  hasValue,
}

// moment показывает время так, как его читает человек в этом часовом поясе.
//
// В базе всё лежит в UTC, но администратор смотрит на панель из своего дня:
// «выдан в 12:00» должно означать полдень у него, а не в Гринвиче.
func moment(t time.Time) string {
	if t.IsZero() {
		return "—"
	}
	return t.Local().Format("02.01.2006, 15:04")
}

func day(t time.Time) string {
	if t.IsZero() {
		return "—"
	}
	return t.Local().Format("02.01.2006")
}

// ago показывает срок словами: «через 2 дня», «14 часов назад».
//
// Рядом с точным временем, а не вместо него: «через два дня» отвечает на
// вопрос «успеет ли человек», а точная дата — на вопрос «когда именно».
func ago(t time.Time) string {
	if t.IsZero() {
		return ""
	}

	d := time.Until(t)
	future := d > 0
	if !future {
		d = -d
	}

	if d < time.Minute {
		return "только что"
	}
	if future {
		return "через " + spell(d, up)
	}
	return spell(d, down) + " назад"
}

// remaining — сколько осталось, без предлога.
//
// Отдельно от ago, потому что предлог принадлежит не сроку, а фразе: рядом с
// «годен ещё» вставленное «через» даёт «годен ещё через день». Первая же живая
// проверка это и показала.
func remaining(t time.Time) string {
	d := time.Until(t)
	if d <= 0 {
		return "срок вышел"
	}
	if d < time.Minute {
		return "меньше минуты"
	}
	return spell(d, up)
}

// Как округлять при переводе в крупную единицу.
//
// Разница не косметическая. Срок, посчитанный от «выпущен плюс двое суток»,
// через миллисекунду после выпуска равен 47 часам 59 минутам — и округление
// вниз написало бы «годен ещё 1 день» ровно в тот момент, когда ключ только
// что выдан. А прошедшее время в журнале, наоборот, округляют вниз: «3 часа
// назад» о событии трёхчасовой давности честнее, чем «4 часа назад».
type rounding int

const (
	up rounding = iota
	down
)

// spell выражает длительность словами в самой крупной подходящей единице.
func spell(d time.Duration, mode rounding) string {
	round := func(v float64) int {
		if mode == up {
			return int(math.Ceil(v))
		}
		return int(v)
	}

	switch {
	case d < time.Hour:
		n := round(d.Minutes())
		return fmt.Sprintf("%d %s", n, plural(n, "минуту", "минуты", "минут"))
	case d < 24*time.Hour:
		n := round(d.Hours())
		return fmt.Sprintf("%d %s", n, plural(n, "час", "часа", "часов"))
	default:
		n := round(d.Hours() / 24)
		return fmt.Sprintf("%d %s", n, plural(n, "день", "дня", "дней"))
	}
}

// plural склоняет по русским правилам.
//
// Нужен потому, что «1 ключ», «2 ключа» и «5 ключей» — три разные формы, и
// «5 ключ(ей)» в интерфейсе, который смотрят каждый день, читается как
// недоделка.
func plural(n int, one, few, many string) string {
	if n < 0 {
		n = -n
	}
	if n%100 >= 11 && n%100 <= 14 {
		return many
	}
	switch n % 10 {
	case 1:
		return one
	case 2, 3, 4:
		return few
	default:
		return many
	}
}

func deref(v *int64) int64 {
	if v == nil {
		return 0
	}
	return *v
}

func hasValue(v *int64) bool { return v != nil }
