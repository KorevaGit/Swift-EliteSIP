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
	key := Key("K7M29XQP4TFB")

	first := key.ObjectKey()
	if first != key.ObjectKey() {
		t.Fatal("адрес пакета непостоянен")
	}
	if len(first) != 32 {
		t.Errorf("длина адреса %d, ожидалась 32: %q", len(first), first)
	}

	other := Key("K7M29XQP4TFC")
	if other.ObjectKey() == first {
		t.Error("разные ключи дали один адрес")
	}
}

func TestSealOpenRoundTrip(t *testing.T) {
	key, err := New()
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	want := []byte(`{"number":"172","sip_password":"secret"}`)

	sealed, err := Seal(key, want)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if bytes.Contains(sealed, want) {
		t.Fatal("содержимое пакета лежит открытым текстом")
	}

	got, err := Open(key, sealed)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("распечатано %q, запечатывалось %q", got, want)
	}
}

func TestOpenRejectsWrongKey(t *testing.T) {
	sealed, err := Seal(Key("K7M29XQP4TFB"), []byte("секрет"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	if _, err := Open(Key("K7M29XQP4TFC"), sealed); err == nil {
		t.Fatal("пакет открылся чужим ключом")
	}
}

// Подделанный байт должен ломать пакет целиком, а не проходить незаметно:
// внутри лежат адрес АТС и SIP-пароль.
func TestOpenRejectsTamperedPackage(t *testing.T) {
	key := Key("K7M29XQP4TFB")
	sealed, err := Seal(key, []byte("секрет"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	for _, at := range []int{len(magic), len(magic) + nonceLen, len(sealed) - 1} {
		broken := bytes.Clone(sealed)
		broken[at] ^= 0x01
		if _, err := Open(key, broken); err == nil {
			t.Errorf("подделка байта %d прошла", at)
		}
	}
}

func TestOpenRejectsForeignFormat(t *testing.T) {
	key := Key("K7M29XQP4TFB")
	sealed, err := Seal(key, []byte("секрет"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	sealed[len(magic)-1] = '9'

	_, err = Open(key, sealed)
	if err == nil {
		t.Fatal("пакет чужой версии открылся")
	}
	if err == ErrWrongKey {
		t.Error("чужая версия формата выдана за неверный ключ — сообщение уведёт разбор не туда")
	}
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
