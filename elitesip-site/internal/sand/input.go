package sand

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Пределы разбора.
//
// Не защита от злоумышленника — своих же опечаток: группа это 5–30 человек, и
// пул номеров у неё того же порядка. Диапазон «1-99999», набранный вместо
// «301-330», без предела молча завёл бы девяносто девять тысяч номеров и
// заодно занял бы их все для остальных песков.
const (
	maxExtensionsInPool = 500
	maxDealsInPool      = 100000
	maxExtensionDigits  = 8
)

// ParseExtensions разворачивает пул номеров из того, что набрали в поле.
//
// Диапазон «301-330» разворачивается: это самый частый способ их выдачи, и
// перечислять тридцать номеров руками никто не станет. Разделителем служит
// что угодно из запятой, точки с запятой и пробела — набирают их вперемешку.
func ParseExtensions(raw string) ([]string, error) {
	var out []string
	for _, token := range splitList(raw) {
		from, to, ok := strings.Cut(token, "-")
		if !ok {
			number, err := extensionNumber(token)
			if err != nil {
				return nil, err
			}
			out = append(out, number)
			continue
		}

		first, err := extensionNumber(from)
		if err != nil {
			return nil, err
		}
		last, err := extensionNumber(to)
		if err != nil {
			return nil, err
		}

		start, _ := strconv.Atoi(first)
		end, _ := strconv.Atoi(last)
		if end < start {
			return nil, fmt.Errorf("диапазон %q идёт назад: начало больше конца", token)
		}
		if end-start+1 > maxExtensionsInPool {
			return nil, fmt.Errorf("диапазон %q — это %d номеров; столько в песок не выдают, проверьте опечатку",
				token, end-start+1)
		}

		// Ведущие нули сохраняются: «0301» и «301» на АТС разные номера, и
		// придумывать за человека, какой он имел в виду, нельзя.
		width := len(first)
		for value := start; value <= end; value++ {
			out = append(out, pad(value, width))
		}
	}

	out = unique(out)
	if len(out) > maxExtensionsInPool {
		return nil, fmt.Errorf("в пуле %d номеров, а больше %d в песок не выдают", len(out), maxExtensionsInPool)
	}
	return out, nil
}

func extensionNumber(token string) (string, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return "", fmt.Errorf("в списке номеров пустое место — уберите лишний разделитель")
	}
	if len(token) > maxExtensionDigits {
		return "", fmt.Errorf("%q не похож на внутренний номер: слишком длинный", token)
	}
	for _, r := range token {
		if r < '0' || r > '9' {
			return "", fmt.Errorf("%q не похож на внутренний номер: в нём не только цифры", token)
		}
	}
	return token, nil
}

func pad(value, width int) string {
	number := strconv.Itoa(value)
	if len(number) >= width {
		return number
	}
	return strings.Repeat("0", width-len(number)) + number
}

// splitList режет набранное по любому привычному разделителю.
func splitList(raw string) []string {
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == ';' || r == '\n' || r == '\r' || r == '\t' || r == ' '
	})
	out := make([]string, 0, len(fields))
	for _, field := range fields {
		if field = strings.TrimSpace(field); field != "" {
			out = append(out, field)
		}
	}
	return out
}

// ParseDeals читает пул сделок из выгрузки Битрикса.
//
// Разбор нарочно снисходительный: файл выгружает Битрикс, и его точная форма
// не наша — где-то разделитель запятая, где-то точка с запятой, сверху бывает
// строка заголовка. Берём первое поле каждой строки и оставляем то, что
// состоит из цифр; заголовок и пустые строки отсеиваются сами.
//
// Строгий разбор здесь означал бы отказ принять файл, который человек только
// что выгрузил и видит своими глазами.
func ParseDeals(r io.Reader) ([]string, error) {
	scanner := bufio.NewScanner(r)
	// Строка выгрузки — это число, но встречаются и длинные строки с лишними
	// столбцами; миллион байт на строку с запасом покрывает и такие.
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var (
		out      []string
		looked   int
		hadCells bool
	)
	for scanner.Scan() {
		line := strings.TrimPrefix(scanner.Text(), "\uFEFF") // Excel ставит BOM
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		looked++

		// Заголовок порции сделок — буквально «1, 2», и первая его ячейка
		// состоит из цифр. Без отдельной проверки единица уехала бы в пул как
		// ID сделки: файл этой формы отдаёт сама панель, и обратно его приносят.
		if looked == 1 && strings.ReplaceAll(line, " ", "") == "1,2" {
			hadCells = true
			continue
		}

		first := line
		if at := strings.IndexAny(line, ",;\t"); at >= 0 {
			first = line[:at]
		}
		first = strings.TrimSpace(strings.Trim(strings.TrimSpace(first), `"`))
		if first == "" {
			continue
		}
		hadCells = true

		if !onlyDigits(first) {
			// Заголовок «1, 2» или подпись столбца — не ошибка, просто не сделка.
			continue
		}
		out = append(out, first)
		if len(out) > maxDealsInPool {
			return nil, fmt.Errorf("в файле больше %d сделок — похоже, это не выгрузка холодной базы", maxDealsInPool)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("прочитать файл сделок: %w", err)
	}

	out = unique(out)
	if len(out) == 0 {
		if looked == 0 || !hadCells {
			return nil, fmt.Errorf("файл сделок пуст")
		}
		return nil, fmt.Errorf("в файле не нашлось ни одного ID сделки — в первом столбце должны стоять числа")
	}
	return out, nil
}

func onlyDigits(value string) bool {
	if value == "" {
		return false
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
