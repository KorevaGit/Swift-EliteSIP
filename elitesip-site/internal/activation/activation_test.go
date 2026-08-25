package activation

import (
	"bytes"
	"strings"
	"testing"
)

func TestNewKeyShape(t *testing.T) {
	seen := make(map[Key]bool)

	for i := 0; i < 200; i++ {
		key, err := New()
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		if len(key) != Length {
			t.Fatalf("длина %d, ожидалась %d: %q", len(key), Length, key)
		}
		for _, r := range string(key) {
			if !strings.ContainsRune(alphabet, r) {
				t.Fatalf("знак %q вне алфавита: %q", r, key)
			}
		}
		if seen[key] {
			t.Fatalf("ключ повторился: %q", key)
		}
		seen[key] = true
	}
}

func TestStringGroups(t *testing.T) {
	got := Key("K7M29XQP4TFB").String()
	if got != "K7M2-9XQP-4TFB" {
		t.Errorf("показан как %q", got)
	}
}

// Ключ диктуют по телефону и вставляют из мессенджера. Всё перечисленное здесь
// приходило бы в поле ввода в бою.
func TestParseIsForgiving(t *testing.T) {
	want := Key("K7M29XQP4TFB")

	cases := []string{
		"K7M29XQP4TFB",
		"K7M2-9XQP-4TFB",
		"k7m2-9xqp-4tfb",
		"  K7M2 9XQP 4TFB\n",
		"K7M2-9XQP-4TFB\r\n",
		"K7M2\u00a09XQP\u00a04TFB", // неразрывный пробел из мессенджера
		"K7M2\u200b9XQP\u200b4TFB", // невидимый разделитель оттуда же
		"K7M2—9XQP—4TFB",           // длинное тире вместо дефиса
	}
	for _, in := range cases {
		got, err := Parse(in)
		if err != nil {
			t.Errorf("Parse(%q): %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("Parse(%q) = %q, ожидалось %q", in, got, want)
		}
	}
}

// Знаки, выброшенные из алфавита за схожесть, приводятся к тем, с которыми их
// путают. Иначе человек, прочитавший ноль как «о», получал бы отказ и не
// понимал почему.
func TestParseFixesConfusableCharacters(t *testing.T) {
	cases := map[string]Key{
		"O7M29XQP4TFB": "07M29XQP4TFB",
		"I7M29XQP4TFB": "17M29XQP4TFB",
		"L7M29XQP4TFB": "17M29XQP4TFB",
		"o7m29xqp4tfb": "07M29XQP4TFB",
	}
	for in, want := range cases {
		got, err := Parse(in)
		if err != nil {
			t.Errorf("Parse(%q): %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("Parse(%q) = %q, ожидалось %q", in, got, want)
		}
	}
}

func TestParseRejectsBadInput(t *testing.T) {
	cases := []string{
		"",
		"K7M2-9XQP",           // короче
		"K7M2-9XQP-4TFB-1234", // длиннее
		"K7M2-9XQP-4TF!",      // недопустимый знак
		"Ключ",                // не тот алфавит вовсе
	}
	for _, in := range cases {
		if got, err := Parse(in); err == nil {
			t.Errorf("Parse(%q) прошло и дало %q", in, got)
		}
	}
}

func TestParseRoundTrip(t *testing.T) {
	for i := 0; i < 50; i++ {
		key, err := New()
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		back, err := Parse(key.String())
		if err != nil {
			t.Fatalf("Parse(%q): %v", key.String(), err)
		}
		if back != key {
			t.Fatalf("после показа и разбора %q стал %q", key, back)
		}
	}
}

// Адрес пакета считается из ключа и обеими сторонами одинаково — на этом
// держится то, что панель наружу ничего не открывает.
func TestObjectKeyIsDerivedAndStable(t *testing.T) {
	bound := mustBind(t, "K7M29XQP4TFB", "")

	first := bound.ObjectKey()
	if !strings.HasPrefix(first, ObjectPrefix) {
		t.Errorf("адрес без приставки: %q", first)
	}

	// Приложение считает из ключа только шестнадцатеричную часть: приставка
	// входит в адрес канала раздачи, который ему провижинится.
	if len(bound.ObjectName()) != 32 {
		t.Errorf("длина имени %d, ожидалась 32: %q", len(bound.ObjectName()), bound.ObjectName())
	}
	if again := mustBind(t, "K7M29XQP4TFB", ""); again.ObjectKey() != first {
		t.Fatal("адрес пакета непостоянен")
	}
	if other := mustBind(t, "K7M29XQP4TFC", ""); other.ObjectKey() == first {
		t.Error("разные ключи дали один адрес")
	}
}

// Привязка живёт в адресе, а не в проверке внутри пакета. Не та машина считает
// другой адрес — и не находит там ничего, вместо того чтобы скачать пакет и
// сжечь ключ на проверке.
func TestBindingChangesAddress(t *testing.T) {
	key := Key("K7M29XQP4TFB")

	free := mustBind(t, key, "")
	mine := mustBind(t, key, "8f2c0000")
	yours := mustBind(t, key, "8f2c0001")

	if mine.ObjectKey() == free.ObjectKey() {
		t.Error("привязанный ключ лёг по адресу непривязанного")
	}
	if mine.ObjectKey() == yours.ObjectKey() {
		t.Error("две машины считают один адрес — привязки нет")
	}
	if again := mustBind(t, key, "8f2c0000"); again.ObjectKey() != mine.ObjectKey() {
		t.Error("адрес привязанного ключа непостоянен")
	}
}

// Материал один, но куски у него разные: имя объекта наружу видно всегда, а
// ключ шифрования не должен из него выводиться.
func TestObjectNameDoesNotLeakCipherKey(t *testing.T) {
	bound := mustBind(t, "K7M29XQP4TFB", "")

	sealed, err := bound.Seal([]byte("секрет"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if bytes.Contains(sealed, []byte(bound.ObjectName())) {
		t.Error("имя объекта лежит внутри пакета")
	}
}

func TestSealOpenRoundTrip(t *testing.T) {
	key, err := New()
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	bound := mustBind(t, key, "")
	want := []byte(`{"number":"172","sip_password":"secret"}`)

	sealed, err := bound.Seal(want)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if bytes.Contains(sealed, want) {
		t.Fatal("содержимое пакета лежит открытым текстом")
	}

	got, err := bound.Open(sealed)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("распечатано %q, запечатывалось %q", got, want)
	}
}

func TestOpenRejectsWrongKey(t *testing.T) {
	sealed, err := mustBind(t, "K7M29XQP4TFB", "").Seal([]byte("секрет"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	if _, err := mustBind(t, "K7M29XQP4TFC", "").Open(sealed); err == nil {
		t.Fatal("пакет открылся чужим ключом")
	}
}

// Тот же ключ, но выпущенный на другую машину, не открывает пакет: привязка
// входит в соль, а значит и в ключ шифрования, а не только в адрес.
func TestOpenRejectsWrongBinding(t *testing.T) {
	key := Key("K7M29XQP4TFB")
	sealed, err := mustBind(t, key, "8f2c0000").Seal([]byte("секрет"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	if _, err := mustBind(t, key, "8f2c0001").Open(sealed); err == nil {
		t.Fatal("пакет открылся с чужой привязкой")
	}
}

// Подделанный байт должен ломать пакет целиком, а не проходить незаметно:
// внутри лежат адрес АТС и SIP-пароль.
func TestOpenRejectsTamperedPackage(t *testing.T) {
	bound := mustBind(t, "K7M29XQP4TFB", "")
	sealed, err := bound.Seal([]byte("секрет"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	for _, at := range []int{len(magic), len(magic) + nonceLen, len(sealed) - 1} {
		broken := bytes.Clone(sealed)
		broken[at] ^= 0x01
		if _, err := bound.Open(broken); err == nil {
			t.Errorf("подделка байта %d прошла", at)
		}
	}
}

func TestOpenRejectsForeignFormat(t *testing.T) {
	bound := mustBind(t, "K7M29XQP4TFB", "")
	sealed, err := bound.Seal([]byte("секрет"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	sealed[len(magic)-1] = '9'

	_, err = bound.Open(sealed)
	if err == nil {
		t.Fatal("пакет чужой версии открылся")
	}
	if err == ErrWrongKey {
		t.Error("чужая версия формата выдана за неверный ключ — сообщение уведёт разбор не туда")
	}
}

// Ключ канала не диктуют голосом, поэтому он полон — и хранится обычным
// хешем, без растяжения.
func TestChannelKeyIsFullLength(t *testing.T) {
	seen := make(map[string]bool)
	for i := 0; i < 50; i++ {
		key, err := NewChannelKey()
		if err != nil {
			t.Fatalf("NewChannelKey: %v", err)
		}
		if len(key) != 64 {
			t.Fatalf("длина ключа канала %d, ожидалась 64: %q", len(key), key)
		}
		if seen[key] {
			t.Fatalf("ключ канала повторился: %q", key)
		}
		seen[key] = true

		hash := HashChannelKey(key)
		if len(hash) != 64 {
			t.Fatalf("длина хеша %d, ожидалась 64", len(hash))
		}
		if hash == key {
			t.Fatal("хеш совпал с ключом")
		}
		if HashChannelKey(key) != hash {
			t.Fatal("хеш ключа канала непостоянен")
		}
	}
}

func mustBind(t *testing.T, key Key, binding Binding) *Bound {
	t.Helper()
	bound, err := Bind(key, binding)
	if err != nil {
		t.Fatalf("Bind(%q, %q): %v", key, binding, err)
	}
	return bound
}

func TestFingerprintNeedsSecret(t *testing.T) {
	key := Key("K7M29XQP4TFB")

	first := Fingerprint([]byte("секрет-панели"), key)
	if first != Fingerprint([]byte("секрет-панели"), key) {
		t.Fatal("отпечаток непостоянен — искать активацию по ключу станет нечем")
	}
	if Fingerprint([]byte("другой-секрет"), key) == first {
		t.Error("отпечаток не зависит от секрета сервера")
	}
	if Fingerprint([]byte("секрет-панели"), Key("K7M29XQP4TFC")) == first {
		t.Error("разные ключи дали один отпечаток")
	}
}

func TestInstallationIDIsUnique(t *testing.T) {
	seen := make(map[string]bool)
	for i := 0; i < 100; i++ {
		id, err := NewInstallationID()
		if err != nil {
			t.Fatalf("NewInstallationID: %v", err)
		}
		if len(id) != 32 {
			t.Fatalf("длина идентификатора %d, ожидалась 32: %q", len(id), id)
		}
		if seen[id] {
			t.Fatalf("идентификатор повторился: %q", id)
		}
		seen[id] = true
	}
}
