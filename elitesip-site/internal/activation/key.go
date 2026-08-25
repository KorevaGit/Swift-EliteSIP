// Package activation — ключ активации рабочего места и пакет, который он
// отпирает.
//
// Ключ делает три вещи сразу, и это осознанно:
//
//  1. называет пакет в R2 — адрес выводится из ключа односторонне;
//  2. отпирает пакет — ключ шифрования выводится из него же;
//  3. опознаёт активацию в панели — по отпечатку, который считает панель.
//
// Отсюда главное свойство: панель ключа не хранит. Хранить его значило бы
// держать замок вместе с ключом от него в одной строке базы.
package activation

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"unicode"
)

// alphabet — Crockford Base32.
//
// Из него убраны I, L, O и U: первые три путаются с 1 и 0 на слух и в шрифтах,
// последняя выпала, чтобы из ключа случайно не складывалось слов. Ровно 32
// знака, поэтому пять бит ложатся в знак без остатка и без отбраковки.
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// Length — длина ключа в знаках. Двенадцать знаков по пять бит — 60 бит.
const Length = 12

// groupSize — по сколько знаков разделять при показе.
const groupSize = 4

// Key — ключ активации в каноническом виде: двенадцать знаков алфавита,
// без разделителей.
type Key string

// New выпускает новый ключ.
func New() (Key, error) {
	var raw [8]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("случайные байты для ключа: %w", err)
	}

	// Берём 60 младших бит и раскладываем по пять на знак.
	bits := binary.BigEndian.Uint64(raw[:]) >> 4

	var b strings.Builder
	b.Grow(Length)
	for i := Length - 1; i >= 0; i-- {
		b.WriteByte(alphabet[(bits>>(5*uint(i)))&0x1f])
	}
	return Key(b.String()), nil
}

// ErrMalformed возвращается, когда строка не является ключом.
var ErrMalformed = errors.New("это не ключ активации")

// Parse приводит введённое человеком к каноническому виду.
//
// Терпимость здесь не украшение: ключ диктуют по телефону и вставляют из
// мессенджера вместе с пробелами и переносом. Регистр не важен, знаки, которых
// в алфавите нет по причине схожести, приводятся к тем, с которыми их
// спутали: O к нулю, I и L к единице.
//
// **Разделители не перечисляются списком, а определяются от обратного** —
// беру буквы и цифры, остальное молча выбрасываю. Это правило приложения
// (PanelLink, ActivationKey), и оно здесь не из подражания: первый заход на
// обеих сторонах перечислял разделители поимённо, и в Swift это споткнулось о
// пару CR LF, которая там один Character, а не два. Панель со списком
// оказывалась строже приложения — ключ из мессенджера с неразрывным пробелом
// приложение принимало, а поиск по ключу отвергал как «не ключ», ровно в том
// случае, ради которого поиск и заведён.
func Parse(s string) (Key, error) {
	var b strings.Builder
	b.Grow(Length)

	for _, r := range strings.ToUpper(s) {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			continue
		}
		switch r {
		case 'O':
			r = '0'
		case 'I', 'L':
			r = '1'
		}
		if !strings.ContainsRune(alphabet, r) {
			return "", fmt.Errorf("%w: недопустимый знак %q", ErrMalformed, r)
		}
		b.WriteRune(r)
	}

	if b.Len() != Length {
		return "", fmt.Errorf("%w: нужно %d знаков, получено %d", ErrMalformed, Length, b.Len())
	}
	return Key(b.String()), nil
}

// String показывает ключ группами по четыре знака: K7M2-9XQP-4TFB.
//
// Группы существуют ради человека на другом конце телефона — двенадцать знаков
// подряд диктуются и сверяются заметно хуже.
func (k Key) String() string {
	s := string(k)
	if len(s) != Length {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i += groupSize {
		if i > 0 {
			b.WriteByte('-')
		}
		b.WriteString(s[i : i+groupSize])
	}
	return b.String()
}

// Prefix — первая группа знаков. Панель показывает её в списке, чтобы
// администратор опознал строку, держа выданный ключ в переписке перед глазами.
func (k Key) Prefix() string {
	if len(k) < groupSize {
		return string(k)
	}
	return string(k[:groupSize])
}

// ObjectPrefix — приставка, под которой пакеты лежат в бакете.
//
// Нужна не для порядка, а для разбора на стороне Worker'а: по ней он отличает
// запрос за пакетом от запроса за чем угодно ещё и не отдаёт наружу то, о чём
// его не спрашивали. Приложение о приставке не знает — она входит в адрес
// канала раздачи, который ему и так провижинится.
const ObjectPrefix = "activations/"

// NewInstallationID выпускает идентификатор машины.
//
// Кладётся в пакет и с тех пор сообщается машиной при каждом запросе за файлом
// предустановок. Это единственное, по чему панель вообще узнаёт рабочие места:
// прямого канала от приложения к ней нет.
func NewInstallationID() (string, error) {
	return randomHex(16, "идентификатора машины")
}

// NewChannelKey выпускает помашинный ключ доступа к каналу раздачи.
//
// Тридцать два случайных байта, а не двенадцать знаков: этот ключ не диктуют
// по телефону, его везёт пакет активации. Полная длина здесь бесплатна, и она
// же позволяет Worker'у хранить рядом обычный SHA-256 вместо растяжения.
func NewChannelKey() (string, error) {
	return randomHex(32, "ключа канала")
}

// HashChannelKey — то, что панель кладёт в machines/<installation_id>.
//
// Голый SHA-256 без растяжения, и это не небрежность: ключ канала случаен и
// полон, перебирать в нём нечего. Растяжение нужно ключу активации, у которого
// шестьдесят бит, — см. Bind.
func HashChannelKey(channelKey string) string {
	sum := sha256.Sum256([]byte(channelKey))
	return hex.EncodeToString(sum[:])
}

func randomHex(n int, what string) (string, error) {
	raw := make([]byte, n)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("случайные байты для %s: %w", what, err)
	}
	return hex.EncodeToString(raw), nil
}
