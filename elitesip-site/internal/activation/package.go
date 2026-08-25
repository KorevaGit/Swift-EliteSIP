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
//
// Второй версией стал разбор 25 августа 2026: изменился и вывод ключа, и
// состав содержимого.
const magic = "ESIPA2"

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
	nameLen  = 16
	keyLen   = 32
	nonceLen = 12
)

// ErrWrongKey возвращается, когда пакет не распечатывается этим ключом.
//
// Один ответ на два случая — не тот ключ и испорченный пакет — намеренно:
// подбирающему незачем знать, ошибся он ключом или наткнулся на битый файл.
// То же решение, что у кода восстановления в AdminAccess.
var ErrWrongKey = errors.New("пакет не открывается этим ключом")

// Binding — машина, к которой привязан ключ.
//
// Пустая у ключа активации: машины ещё нет, и привязывать не к чему. У ключа
// перепрошивки — идентификатор той машины, для которой ключ выпущен.
type Binding string

// Bound — ключ вместе с выведенным из него материалом.
//
// Тип существует затем, чтобы прогонка была ровно одна. Имя объекта и ключ
// шифрования — это разные куски одного вывода PBKDF2, и посчитать их по
// отдельности значило бы заплатить второй секундой на Catalina, где человек и
// так ждёт у экрана.
type Bound struct {
	binding Binding
	name    string
	cipher  cipher.AEAD
}

// Bind считает материал ключа: сорок восемь байт одной прогонкой.
//
//	соль  = SHA-256("elitesip.activation.salt.v2\0" + ключ + "\0" + машина)[:16]
//	вывод = PBKDF2-HMAC-SHA256(ключ, соль, 150 000, 48)
//	имя объекта = hex(вывод[0:16])
//	ключ AES    = вывод[16:48]
//
// **Соль выводится из самого ключа, а не берётся случайной.** Обычно так делать
// нельзя, здесь можно: ключ выпускается случайным и живёт двое суток, то есть
// повторов, ради защиты от которых соль и случайна, не бывает. А зато машине не
// приходится знать ничего, кроме ключа: ни соли рядом с шифротекстом, ни
// параметров в заголовке.
//
// **Имя объекта растянуто вместе с ключом шифрования.** До 25 августа 2026 оно
// считалось голым SHA-256 от ключа — а ключ шестьдесят бит, и утёкшая база
// панели давала по каждой строке готовый образ для перебора за 2⁶⁰: недели на
// одной видеокарте. Заявление «панель ключа не хранит» было неверным. Цена
// исправления названа прямо: адресация и шифрование теперь связаны одним
// набором параметров, и поднять итерации, не сломав адресацию, нельзя.
//
// **Привязка живёт в соли.** Не та машина считает другой адрес и получает 404,
// не тронув пакет, — это важнее, чем кажется: Worker столбит пакет в момент
// скачивания, задолго до расшифровки, и проверка привязки внутри пакета
// сжигала бы ключ у того, кто просто перепутал свои же два компьютера.
func Bind(k Key, binding Binding) (*Bound, error) {
	salt := sha256.Sum256([]byte(
		"elitesip.activation.salt.v2\x00" + string(k) + "\x00" + string(binding)))

	derived, err := pbkdf2.Key(sha256.New, string(k), salt[:saltLen], iterations, nameLen+keyLen)
	if err != nil {
		return nil, fmt.Errorf("вывести материал ключа: %w", err)
	}

	block, err := aes.NewCipher(derived[nameLen:])
	if err != nil {
		return nil, fmt.Errorf("шифр пакета: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("режим шифра пакета: %w", err)
	}

	return &Bound{
		binding: binding,
		name:    hex.EncodeToString(derived[:nameLen]),
		cipher:  gcm,
	}, nil
}

// ObjectName — шестнадцатеричная строка, которую машина считает из ключа сама.
func (b *Bound) ObjectName() string { return b.name }

// ObjectKey — имя пакета в бакете, вместе с приставкой раскладки.
func (b *Bound) ObjectKey() string { return ObjectPrefix + b.name }

// Binding — машина, к которой привязан ключ. Пустая у ключа активации.
func (b *Bound) Binding() Binding { return b.binding }

// Seal запечатывает содержимое пакета.
func (b *Bound) Seal(plaintext []byte) ([]byte, error) {
	nonce := make([]byte, nonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("случайные байты для пакета: %w", err)
	}

	out := make([]byte, 0, len(magic)+nonceLen+len(plaintext)+b.cipher.Overhead())
	out = append(out, magic...)
	out = append(out, nonce...)
	// Заголовок идёт в дополнительные данные: подменивший версию в файле
	// получит отказ, а не попытку разобрать чужой формат.
	return b.cipher.Seal(out, nonce, plaintext, []byte(magic)), nil
}

// Open распечатывает пакет.
//
// Живёт рядом с Seal не ради приложения — оно на Swift и делает это само, — а
// ради проверки: обе половины должны сходиться, и это единственный способ
// убедиться в этом тестом.
func (b *Bound) Open(sealed []byte) ([]byte, error) {
	if len(sealed) < len(magic)+nonceLen {
		return nil, ErrWrongKey
	}
	if string(sealed[:len(magic)]) != magic {
		return nil, fmt.Errorf("пакет собран другой версией формата: %q", sealed[:len(magic)])
	}

	nonce := sealed[len(magic) : len(magic)+nonceLen]
	plaintext, err := b.cipher.Open(nil, nonce, sealed[len(magic)+nonceLen:], []byte(magic))
	if err != nil {
		return nil, ErrWrongKey
	}
	return plaintext, nil
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
