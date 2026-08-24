package web

import (
	"strings"
	"testing"
	"time"
)

func TestEmployeeMessageHasEverythingNeeded(t *testing.T) {
	expires := time.Date(2026, 8, 26, 12, 0, 0, 0, time.Local)
	text := employeeMessage("Пётр Смирнов", "K7M2-XXXX-YYYY", expires, "https://elitesip.vip/download")

	for _, want := range []string{
		"Пётр, здравствуйте",
		"K7M2-XXXX-YYYY",
		"https://elitesip.vip/download",
		"«Ввести ключ»",
		"26.08.2026, 12:00",
		"срабатывает один раз",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("в сообщении нет %q:\n%s", want, text)
		}
	}
}

// Обращаются по имени, а не по фамилии: «Смирнов, здравствуйте» звучит как
// вызов к директору.
func TestEmployeeMessageGreetsByFirstName(t *testing.T) {
	text := employeeMessage("Пётр Смирнов", "K7M2", time.Now(), "")
	if !strings.HasPrefix(text, "Пётр, здравствуйте") {
		t.Errorf("обращение вышло такое: %q", text[:30])
	}
}

// Без заданного адреса шаги всё равно должны начинаться с установки: иначе
// первым делом человеку велят открыть программу, которой у него нет.
func TestEmployeeMessageWithoutLinkStillTellsToInstall(t *testing.T) {
	text := employeeMessage("Анна", "K7M2", time.Now(), "")

	if !strings.Contains(text, "1. Установите EliteSIP.") {
		t.Errorf("первый шаг не про установку:\n%s", text)
	}
	if !strings.Contains(text, "2. Откройте программу") {
		t.Errorf("шаги сбились в нумерации:\n%s", text)
	}
	if strings.Contains(text, "http") {
		t.Errorf("в сообщении осталась ссылка, которой нет:\n%s", text)
	}
}
