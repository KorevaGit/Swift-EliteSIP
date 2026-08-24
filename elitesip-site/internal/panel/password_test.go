package panel

import (
	"errors"
	"strings"
	"testing"
)

func TestPasswordRoundTrip(t *testing.T) {
	hash, err := HashPassword("пароль-панели")
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	if err := CheckPassword(hash, "пароль-панели"); err != nil {
		t.Fatalf("CheckPassword: %v", err)
	}
	if err := CheckPassword(hash, "пароль-панелu"); !errors.Is(err, ErrWrongPassword) {
		t.Fatalf("чужой пароль дал %v", err)
	}
}

// Соль случайна: две одинаковые строки не должны выглядеть одинаково в базе.
func TestSamePasswordHashesDifferently(t *testing.T) {
	first, _ := HashPassword("одинаковый")
	second, _ := HashPassword("одинаковый")

	if first == second {
		t.Fatal("два хеша одного пароля совпали — соль не случайна")
	}
	if err := CheckPassword(second, "одинаковый"); err != nil {
		t.Errorf("второй хеш не проверяется: %v", err)
	}
}

// Число итераций лежит в строке, чтобы его можно было поднять, не ломая уже
// заведённых администраторов.
func TestIterationsTravelWithHash(t *testing.T) {
	hash, _ := HashPassword("пароль")
	parts := strings.Split(hash, "$")

	if len(parts) != 4 {
		t.Fatalf("хеш из %d частей: %q", len(parts), hash)
	}
	if parts[0] != "pbkdf2-sha256" || parts[1] != "150000" {
		t.Errorf("схема и итерации: %q, %q", parts[0], parts[1])
	}
}

func TestEmptyPasswordRejected(t *testing.T) {
	if _, err := HashPassword("   "); err == nil {
		t.Fatal("пустой пароль принят")
	}
}

// Испорченная строка должна давать внятную ошибку, а не молчаливый отказ,
// неотличимый от неверного пароля: одно чинится правкой базы, другое — памятью.
func TestBrokenHashIsNotSilentRejection(t *testing.T) {
	for _, stored := range []string{
		"",
		"мусор",
		"pbkdf2-sha256$нечисло$c29sdA$aGFzaA",
		"scrypt$1$c29sdA$aGFzaA",
	} {
		err := CheckPassword(stored, "пароль")
		if err == nil {
			t.Errorf("испорченный хеш %q пропустил вход", stored)
			continue
		}
		if errors.Is(err, ErrWrongPassword) {
			t.Errorf("испорченный хеш %q выдан за неверный пароль", stored)
		}
	}
}
