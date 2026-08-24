package web

import (
	"testing"
	"time"
)

// Предлог принадлежит фразе, а не сроку: рядом с «годен ещё» вставленное
// «через» даёт «годен ещё через день». Нашлось живой проверкой.
func TestRemainingHasNoPreposition(t *testing.T) {
	// Округление вверх: срок «выпущен плюс двое суток» через миллисекунду
	// после выпуска равен 47:59, и округление вниз написало бы «1 день» ровно
	// тогда, когда ключ только что выдан.
	cases := map[time.Duration]string{
		48 * time.Hour:   "2 дня",
		47 * time.Hour:   "2 дня",
		25 * time.Hour:   "2 дня",
		5 * time.Hour:    "5 часов",
		2 * time.Hour:    "2 часа",
		20 * time.Minute: "20 минут",
		2 * time.Minute:  "2 минуты",
		30 * time.Second: "меньше минуты",
	}
	for in, want := range cases {
		if got := remaining(time.Now().Add(in)); got != want {
			t.Errorf("remaining(+%s) = %q, ожидалось %q", in, got, want)
		}
	}

	if got := remaining(time.Now().Add(-time.Hour)); got != "срок вышел" {
		t.Errorf("для прошедшего срока: %q", got)
	}
}

func TestAgoKeepsPreposition(t *testing.T) {
	if got := ago(time.Now().Add(26 * time.Hour)); got != "через 2 дня" {
		t.Errorf("для будущего: %q", got)
	}
	if got := ago(time.Now().Add(-3 * time.Hour)); got != "3 часа назад" {
		t.Errorf("для прошлого: %q", got)
	}
	if got := ago(time.Time{}); got != "" {
		t.Errorf("для пустого времени: %q", got)
	}
}

// «5 ключ(ей)» в интерфейсе, который смотрят каждый день, читается как
// недоделка.
func TestPluralFollowsRussianRules(t *testing.T) {
	cases := map[int]string{
		1: "ключ", 2: "ключа", 4: "ключа", 5: "ключей",
		11: "ключей", 12: "ключей", 14: "ключей",
		21: "ключ", 22: "ключа", 25: "ключей",
		101: "ключ", 111: "ключей", 0: "ключей",
	}
	for n, want := range cases {
		if got := plural(n, "ключ", "ключа", "ключей"); got != want {
			t.Errorf("plural(%d) = %q, ожидалось %q", n, got, want)
		}
	}
}

func TestMomentHandlesZeroTime(t *testing.T) {
	if got := moment(time.Time{}); got != "—" {
		t.Errorf("для пустого времени: %q", got)
	}
	if got := day(time.Time{}); got != "—" {
		t.Errorf("для пустой даты: %q", got)
	}
}
