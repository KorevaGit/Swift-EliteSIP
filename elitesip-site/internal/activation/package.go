package activation

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
)

// magic — заголовок пакета. Версия в нём затем, чтобы старая машина не
// пыталась расшифровать формат, о котором не знает, и сказала об этом прямо
// вместо «неверный ключ».
const magic = "ESIPA1"

// iterations — итерации PBKDF2.
//
// PBKDF2-HMAC-SHA256, а не Argon2id, по одной причине: распечатывает пакет
// клиент на macOS, нижняя планка которого — Catalina. Argon2 там нет ни в
// CryptoKit, ни в CommonCrypto, то есть он означал бы новую зависимость в
// приложении, которое держат однозависимым намеренно. PBKDF2 у клиента уже
// написан и работает — Packages/AdminAccess KeyDerivation.swift, — и число
// итераций взято оттуда же.
const iterations = 150_000

const (
	saltLen  = 16
	keyLen   = 32
	nonceLen = 12
)

// ErrWrongKey возвращается, когда пакет не распечатывается этим ключом.
//
// Один ответ на два случая — не тот ключ и испорченный пакет — намеренно:
// подбирающему незачем знать, ошибся он ключом или наткнулся на битый файл.
// То же решение, что у кода восстановления в AdminAccess.
var ErrWrongKey = errors.New("пакет не открывается этим ключом")

// Seal запечатывает содержимое пакета ключом.
//
// Соль выводится из самого ключа, а не берётся случайной. Обычно так делать
// нельзя, здесь можно: ключ выпускается случайным и живёт двое суток, то есть
// повторов, ради защиты от которых соль и случайна, не бывает. А зато машине
// не приходится знать ничего, кроме ключа: ни соли рядом с шифротекстом, ни
// параметров в заголовке.
func Seal(key Key, plaintext []byte) ([]byte, error) {
	gcm, err := key.cipher()
	if err != nil {
		return nil, err
	}

	nonce := make([]byte, nonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("случайные байты для пакета: %w", err)
	}

	out := make([]byte, 0, len(magic)+nonceLen+len(plaintext)+gcm.Overhead())
	out = append(out, magic...)
	out = append(out, nonce...)
	// Заголовок идёт в дополнительные данные: подменивший версию в файле
	// получит отказ, а не попытку разобрать чужой формат.
	return gcm.Seal(out, nonce, plaintext, []byte(magic)), nil
}

// Open распечатывает пакет.
//
// Живёт рядом с Seal не ради приложения — оно на Swift и делает это само, — а
// ради проверки: обе половины должны сходиться, и это единственный способ
// убедиться в этом тестом.
func Open(key Key, sealed []byte) ([]byte, error) {
	if len(sealed) < len(magic)+nonceLen {
		return nil, ErrWrongKey
	}
	if string(sealed[:len(magic)]) != magic {
		return nil, fmt.Errorf("пакет собран другой версией формата: %q", sealed[:len(magic)])
	}

	gcm, err := key.cipher()
	if err != nil {
		return nil, err
	}

	nonce := sealed[len(magic) : len(magic)+nonceLen]
	plaintext, err := gcm.Open(nil, nonce, sealed[len(magic)+nonceLen:], []byte(magic))
	if err != nil {
		return nil, ErrWrongKey
	}
	return plaintext, nil
}

func (k Key) cipher() (cipher.AEAD, error) {
	salt := sha256.Sum256([]byte("elitesip.activation.salt.v1\x00" + string(k)))

	derived, err := pbkdf2.Key(sha256.New, string(k), salt[:saltLen], iterations, keyLen)
	if err != nil {
		return nil, fmt.Errorf("вывести ключ пакета: %w", err)
	}

	block, err := aes.NewCipher(derived)
	if err != nil {
		return nil, fmt.Errorf("шифр пакета: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("режим шифра пакета: %w", err)
	}
	return gcm, nil
}

// Fingerprint — то, что панель хранит вместо ключа.
//
// HMAC с серверным секретом, а не голый хеш: 60 бит ключа перебираются, и
// утёкшая база без секрета не должна давать возможности восстановить по строке
// сам ключ. Отпечаток при этом детерминированный — иначе администратор не смог
// бы найти активацию по ключу, который ему прислал сотрудник.
func Fingerprint(secret []byte, k Key) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte("elitesip.activation.fingerprint.v1\x00"))
	mac.Write([]byte(k))
	return hex.EncodeToString(mac.Sum(nil))
}
