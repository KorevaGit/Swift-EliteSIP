package web

import (
	"strconv"
	"strings"
	"time"
)

// employeeMessage собирает готовый текст сотруднику.
//
// Существует ради одной беды: ключ переписывают с экрана руками и ошибаются в
// одном знаке. Готовое сообщение убирает и это, и второй заход техподдержки с
// объяснением, куда ключ вводить.
//
// Собирается на сервере, а не в браузере: те же слова показываются на экране,
// и склеивать их дважды — верный способ развести показанное с отправленным.
func employeeMessage(name, key string, expires time.Time, appLink string) string {
	var b strings.Builder

	if name != "" {
		b.WriteString(shortName(name) + ", здравствуйте! ")
	}
	b.WriteString("Вот ключ для настройки рабочего телефона EliteSIP:\n\n")
	b.WriteString(key + "\n\n")

	step := 1
	if appLink != "" {
		b.WriteString(numbered(&step, "Установите EliteSIP: "+appLink))
	} else {
		// Адрес не задан — строка всё равно нужна, иначе шаги начинаются с
		// «откройте программу», которой у человека ещё нет.
		b.WriteString(numbered(&step, "Установите EliteSIP."))
	}
	b.WriteString(numbered(&step, "Откройте программу и на первом экране нажмите «Ввести ключ»."))
	b.WriteString(numbered(&step, "Введите ключ. Номер, пароль и настройки приедут сами."))

	b.WriteString("\nКлюч действует до " + moment(expires) +
		" и срабатывает один раз. Если не сработал — напишите нам, выпустим новый.")
	return b.String()
}

func numbered(n *int, text string) string {
	line := strconv.Itoa(*n) + ". " + text + "\n"
	*n++
	return line
}

// shortName — то, как к человеку обращаются в переписке.
//
// Первое слово, потому что в базе лежит «Пётр Смирнов», а сообщение начинается
// с обращения: «Смирнов, здравствуйте» звучит как вызов к директору.
func shortName(name string) string {
	if i := strings.IndexByte(name, ' '); i > 0 {
		return name[:i]
	}
	return name
}

// reflashMessage — текст сотруднику, чью машину перепрошивают.
//
// Отдельно от employeeMessage, а не флагом внутри неё: шаги другие целиком.
// Приложение уже стоит и работает, качать нечего, а ввод идёт не в мастере
// первоначальной настройки, до которого ещё надо добраться, а в разделе, где
// человек никогда не был.
func reflashMessage(name, key string, expires time.Time, appLink string) string {
	var b strings.Builder

	if name != "" {
		b.WriteString(shortName(name) + ", здравствуйте! ")
	}
	b.WriteString("Ваше рабочее место переезжает на новые настройки. Вот ключ:\n\n")
	b.WriteString(key + "\n\n")

	step := 1
	b.WriteString(numbered(&step, "Откройте EliteSIP → «Меню» → «Техподдержка»."))
	b.WriteString(numbered(&step, "Введите ключ в поле «Новый ключ»."))
	b.WriteString(numbered(&step, "Если идёт разговор — ничего не прервётся: настройки применятся, как только положите трубку."))

	b.WriteString("\nНомер и настройки сменятся сами. Ключ действует до " + moment(expires) +
		", срабатывает один раз и только на вашем компьютере.")
	if appLink != "" {
		b.WriteString(" Приложение переустанавливать не нужно.")
	}
	return b.String()
}
