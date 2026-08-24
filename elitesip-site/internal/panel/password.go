package panel

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Параметры разбора пароля администратора.
//
// PBKDF2-HMAC-SHA256 со 150 000 итераций — те же, что у административного
// пароля в самом приложении (Packages/AdminAccess). Одинаковость здесь не ради
// красоты: две разные стойкости в одном продукте пришлось бы объяснять, а
// объяснения такого рода забываются раньше, чем понадобятся.
const (
	passwordIterations = 150_000
	passwordSaltLen    = 16
	passwordKeyLen     = 32
	passwordScheme     = "pbkdf2-sha256"
)

// ErrWrongPassword — пароль не подошёл.
var ErrWrongPassword = errors.New("неверный пароль")

// HashPassword готовит пароль к хранению.
//
// Формат — `pbkdf2-sha256$150000$соль$хеш`, всё в base64. Число итераций лежит
// в самой строке, чтобы его можно было поднять, не ломая уже заведённых
// администраторов: старые строки проверятся своим числом, новые — новым.
func HashPassword(password string) (string, error) {
	if strings.TrimSpace(password) == "" {
		return "", errors.New("пустой пароль")
	}

	salt := make([]byte, passwordSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("случайные байты для соли: %w", err)
	}

	key, err := pbkdf2.Key(sha256.New, password, salt, passwordIterations, passwordKeyLen)
	if err != nil {
		return "", fmt.Errorf("вывести хеш пароля: %w", err)
	}

	return fmt.Sprintf("%s$%d$%s$%s",
		passwordScheme, passwordIterations,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}

// CheckPassword сверяет пароль с хранимой строкой.
func CheckPassword(stored, password string) error {
	parts := strings.Split(stored, "$")
	if len(parts) != 4 || parts[0] != passwordScheme {
		return fmt.Errorf("хеш пароля непонятного вида")
	}

	iterations, err := strconv.Atoi(parts[1])
	if err != nil || iterations <= 0 {
		return fmt.Errorf("хеш пароля с непонятным числом итераций: %q", parts[1])
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[2])
	if err != nil {
		return fmt.Errorf("хеш пароля с испорченной солью: %w", err)
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[3])
	if err != nil {
		return fmt.Errorf("испорченный хеш пароля: %w", err)
	}

	got, err := pbkdf2.Key(sha256.New, password, salt, iterations, len(want))
	if err != nil {
		return fmt.Errorf("вывести хеш пароля: %w", err)
	}

	// Сравнение постоянного времени: разница во времени ответа рассказывает,
	// сколько байтов угадано, и превращает подбор в перебор по одному байту.
	if subtle.ConstantTimeCompare(got, want) != 1 {
		return ErrWrongPassword
	}
	return nil
}
