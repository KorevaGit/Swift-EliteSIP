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
// мессенджера вместе с пробелами и переносом. Регистр не важен, разделители
// любые, а знаки, которых в алфавите нет по причине схожести, приводятся к
// тем, с которыми их спутали: O к нулю, I и L к единице.
func Parse(s string) (Key, error) {
	var b strings.Builder
	b.Grow(Length)

	for _, r := range strings.ToUpper(s) {
		switch {
		case r == '-' || r == ' ' || r == '\t' || r == '\n' || r == '\r':
			continue
		case r == 'O':
			r = '0'
		case r == 'I' || r == 'L':
			r = '1'
		}
		if !strings.ContainsRune(alphabet, r) {
			return "", fmt.Errorf("%w: недопустимый знак %q", ErrMalformed, r)
		}
		if b.Len() == Length {
			return "", fmt.Errorf("%w: длиннее %d знаков", ErrMalformed, Length)
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

// ObjectKey — имя пакета в бакете.
//
// Считается из ключа односторонне, поэтому его знает и панель (при выпуске), и
// машина (при активации), а сервер посередине не нужен. Знание адреса при этом
// ничего не даёт: пакет по нему лежит зашифрованный тем же ключом.
func (k Key) ObjectKey() string {
	return ObjectPrefix + k.objectName()
}

// objectName — та самая шестнадцатеричная строка, которую машина считает из
// ключа сама.
func (k Key) objectName() string {
	sum := sha256.Sum256([]byte("elitesip.activation.object.v1\x00" + string(k)))
	return hex.EncodeToString(sum[:16])
}

// NewInstallationID выпускает идентификатор машины.
//
// Кладётся в пакет и с тех пор сообщается машиной при каждом запросе за файлом
// предустановок. Это единственное, по чему панель вообще узнаёт рабочие места:
// прямого канала от приложения к ней нет.
func NewInstallationID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("случайные байты для идентификатора машины: %w", err)
	}
	return hex.EncodeToString(raw[:]), nil
}
