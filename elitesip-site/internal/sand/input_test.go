package sand

import (
	"strings"
	"testing"
)

// Диапазон разворачивается: перечислять тридцать номеров руками никто не
// станет, а «301-330» — самый частый способ их выдачи.
func TestParseExtensionsExpandsRanges(t *testing.T) {
	got, err := ParseExtensions("301-305")
	if err != nil {
		t.Fatalf("ParseExtensions: %v", err)
	}
	want := []string{"301", "302", "303", "304", "305"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("вышло %v, ожидалось %v", got, want)
	}
}

// Разделители набирают вперемешку, и повтор в одной форме — не ошибка, а
// диапазон, куда рядом дописали тот же номер.
func TestParseExtensionsAcceptsMixedSeparators(t *testing.T) {
	got, err := ParseExtensions(" 301, 302;303\n304\t305 302 ")
	if err != nil {
		t.Fatalf("ParseExtensions: %v", err)
	}
	if want := "301,302,303,304,305"; strings.Join(got, ",") != want {
		t.Errorf("вышло %v, ожидалось %s", got, want)
	}
}

// Ведущий ноль сохраняется: «0301» и «301» на АТС разные номера, и решать за
// человека, какой он имел в виду, нельзя.
func TestParseExtensionsKeepsLeadingZeroes(t *testing.T) {
	got, err := ParseExtensions("0301-0303")
	if err != nil {
		t.Fatalf("ParseExtensions: %v", err)
	}
	if want := "0301,0302,0303"; strings.Join(got, ",") != want {
		t.Errorf("вышло %v, ожидалось %s", got, want)
	}
}

// Опечатку разбор ловит и называет: «1-99999» вместо «301-330» без предела
// молча занял бы девяносто девять тысяч номеров на все пески сразу.
func TestParseExtensionsRefusesNonsense(t *testing.T) {
	for name, raw := range map[string]string{
		"буквы в номере":  "301, три-ноль-два",
		"диапазон назад":  "330-301",
		"огромный размах": "1-99999",
		"слишком длинный": "1234567890",
	} {
		got, err := ParseExtensions(raw)
		if err == nil {
			t.Errorf("%s: %q принят и дал %v", name, raw, got)
			continue
		}
		if strings.TrimSpace(err.Error()) == "" {
			t.Errorf("%s: отказ без объяснения", name)
		}
	}
}

// Пустое поле — это пустой пул, а не отказ: номера дописываются по ходу.
func TestParseExtensionsAllowsEmptyPool(t *testing.T) {
	got, err := ParseExtensions("   \n ")
	if err != nil {
		t.Fatalf("пустое поле дало ошибку: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("из пустого поля вышли номера: %v", got)
	}
}

// Файл выгружает Битрикс, и его форма не наша: заголовок, точки с запятой и
// лишние столбцы разбор переживает, потому что отказ принять только что
// выгруженный файл человеку объяснить нечем.
func TestParseDealsSurvivesRealExports(t *testing.T) {
	cases := map[string]string{
		"как ждёт импорт":     "1, 2\n2516934, 10660\n2517017, 10660\n",
		"точка с запятой":     "ID;Название\n2516934;Клиент\n2517017;Клиент\n",
		"один столбец":        "2516934\n2517017\n",
		"кавычки и пустые":    "\"2516934\"\n\n\"2517017\"\n",
		"с BOM от Excel":      "\uFEFFID\n2516934\n2517017\n",
		"перевод строки CRLF": "ID\r\n2516934\r\n2517017\r\n",
	}

	for name, raw := range cases {
		got, err := ParseDeals(strings.NewReader(raw))
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if want := "2516934,2517017"; strings.Join(got, ",") != want {
			t.Errorf("%s: вышло %v", name, got)
		}
	}
}

// Повторы в выгрузке убираются: одна сделка не может достаться двум людям, и
// начинается это с пула.
func TestParseDealsDropsRepeats(t *testing.T) {
	got, err := ParseDeals(strings.NewReader("2516934\n2516934\n2517017\n"))
	if err != nil {
		t.Fatalf("ParseDeals: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("сделок вышло %d: %v", len(got), got)
	}
}

// Не тот файл разбор не проглатывает молча: пустой пул сделок выглядел бы как
// успешная загрузка, а потом «кнопка 300 ничего не отдаёт».
func TestParseDealsRefusesFileWithoutDeals(t *testing.T) {
	for name, raw := range map[string]string{
		"пустой файл":     "",
		"одни пробелы":    "  \n\n  \n",
		"только заголовк": "Название;Ответственный\nКлиент;Пётр\n",
	} {
		if got, err := ParseDeals(strings.NewReader(raw)); err == nil {
			t.Errorf("%s: принят и дал %v", name, got)
		}
	}
}
