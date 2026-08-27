package web

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"html/template"
	"math"
	"reflect"
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
	"width":     width,
	"dayAt":     dayAt,
	"add":       func(a, b int) int { return a + b },
	"asset":     assetURL,
}

// assetURL дописывает к статике отпечаток её содержимого.
//
// Метка в ссылке была проставлена руками — `?v=compact-1`, — и с тех пор не
// менялась ни разу, сколько бы ни правили сам лист. Браузер администратора
// держал стиль месячной давности и показывал прошлую панель поверх свежей
// разметки; поймать это можно было только жёсткой перезагрузкой, о которой
// надо догадаться. Ровно на это ушёл круг проверки 27 августа 2026.
//
// Отпечаток считается один раз при запуске: файлы вшиты в бинарь `go:embed`,
// и меняются они только вместе с ним.
func assetURL(name string) string {
	if sum, ok := assetSums[name]; ok {
		return "/static/" + name + "?v=" + sum
	}
	return "/static/" + name
}

var assetSums = map[string]string{}

// hashAssets считает отпечатки вшитой статики. Зовётся при сборке сервера.
func hashAssets(read func(string) ([]byte, error), names ...string) {
	for _, name := range names {
		data, err := read("static/" + name)
		if err != nil {
			continue
		}
		sum := sha256.Sum256(data)
		assetSums[name] = hex.EncodeToString(sum[:])[:12]
	}
}

// dayAt — дата необязательного времени.
//
// Отдельно от day, потому что в песочнице половина времён — указатели: песок
// может быть не закрыт, исход не наступить. Разыменовывать их в разметке
// значило бы уронить страницу на первом же незакрытом песке.
func dayAt(t *time.Time) string {
	if t == nil {
		return "—"
	}
	return day(*t)
}

// width — ширина полоски выполненного.
//
// Отдельной функцией, а не числом прямо в разметке: значение в атрибуте style
// html/template проверяет, и объявить его безопасным правильнее один раз здесь,
// заодно прибив процент к границам. Полоска рисуется без JS — на странице,
// которую открывают с выключенными скриптами, она обязана остаться правдивой.
func width(percent int) template.CSS {
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	return template.CSS(fmt.Sprintf("width:%d%%", percent))
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

// deref и hasValue берут любой указатель, а не только *int64.
//
// Через reflect, потому что в шаблоны приезжают и *int64 (номера строк базы), и
// *int (версия схемы, ревизия предустановки у машины). Две пары функций с
// именами вроде deref64 читались бы в разметке как разные действия, хотя
// действие одно.
func deref(v any) int64 {
	value := reflect.ValueOf(v)
	if !value.IsValid() || value.Kind() != reflect.Pointer || value.IsNil() {
		return 0
	}
	return value.Elem().Int()
}

func hasValue(v any) bool {
	value := reflect.ValueOf(v)
	return value.IsValid() && value.Kind() == reflect.Pointer && !value.IsNil()
}
