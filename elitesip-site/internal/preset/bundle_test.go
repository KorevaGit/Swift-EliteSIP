package preset

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func testBundle(t *testing.T) Bundle {
	t.Helper()

	fields, err := validFields(t).Canonical()
	if err != nil {
		t.Fatalf("Canonical: %v", err)
	}
	return Bundle{
		Format:      BundleFormat,
		GeneratedAt: time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC),
		Presets: []Entry{{
			ID:            "6D1F5A20-0000-4000-8000-000000000001",
			Name:          "Менеджер",
			Revision:      12,
			SchemaVersion: SchemaVersion,
			Fields:        fields,
		}},
	}
}

func testKeys(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	return pub, priv
}

func TestSignVerifyRoundTrip(t *testing.T) {
	pub, priv := testKeys(t)
	want := testBundle(t)

	signed, err := Sign(want, priv)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	got, err := Verify(signed, pub)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if len(got.Presets) != 1 {
		t.Fatalf("предустановок %d, ожидалась одна", len(got.Presets))
	}
	if got.Presets[0].ID != want.Presets[0].ID || got.Presets[0].Revision != 12 {
		t.Errorf("прочитано %+v", got.Presets[0])
	}
	if !got.GeneratedAt.Equal(want.GeneratedAt) {
		t.Errorf("время сборки %s, ожидалось %s", got.GeneratedAt, want.GeneratedAt)
	}
}

// Подделанный байт должен ломать файл целиком: внутри лежат адреса АТС.
func TestVerifyRejectsTampering(t *testing.T) {
	pub, priv := testKeys(t)

	signed, err := Sign(testBundle(t), priv)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	// Подмена внутри payload — самый правдоподобный случай: адрес АТС уводится
	// на чужой сервер, а всё остальное остаётся правдоподобным.
	var container Signed
	if err := json.Unmarshal(signed, &container); err != nil {
		t.Fatalf("разобрать: %v", err)
	}
	spoiled := bytes.Replace(container.Payload,
		[]byte("crm.elitesochi.com"), []byte("crm.elitesochi.cam"), 1)
	if bytes.Equal(spoiled, container.Payload) {
		t.Fatal("подмена не удалась — тест ничего не проверяет")
	}
	container.Payload = spoiled

	broken, err := json.Marshal(container)
	if err != nil {
		t.Fatalf("собрать: %v", err)
	}
	if _, err := Verify(broken, pub); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("подменённый адрес АТС прошёл проверку: %v", err)
	}
}

func TestVerifyRejectsForeignKey(t *testing.T) {
	_, priv := testKeys(t)
	otherPub, _ := testKeys(t)

	signed, err := Sign(testBundle(t), priv)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	if _, err := Verify(signed, otherPub); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("файл прошёл проверку чужим ключом: %v", err)
	}
}

func TestVerifyRejectsTruncated(t *testing.T) {
	pub, priv := testKeys(t)

	signed, err := Sign(testBundle(t), priv)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	if _, err := Verify(signed[:len(signed)/2], pub); err == nil {
		t.Fatal("обрезанный файл прошёл проверку")
	}
}

// Файл новее этой стороны — отдельная беда с отдельным сообщением: он целый и
// подписан верно, просто мы его не понимаем.
func TestVerifyReportsNewerFormatSeparately(t *testing.T) {
	pub, priv := testKeys(t)

	bundle := testBundle(t)
	bundle.Format = BundleFormat + 1
	signed, err := Sign(bundle, priv)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	_, err = Verify(signed, pub)
	if err == nil {
		t.Fatal("файл будущей версии прошёл")
	}
	if errors.Is(err, ErrBadSignature) {
		t.Error("новая версия формата выдана за неверную подпись — разбор уйдёт не туда")
	}
}

// Подпись считается по тем же байтам, что лежат в файле: перестановка ключей
// чужим разбором не должна ломать проверку.
func TestSignatureCoversStoredBytes(t *testing.T) {
	pub, priv := testKeys(t)

	signed, err := Sign(testBundle(t), priv)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	// Пересобираем внешний контейнер, не трогая payload, — так поступил бы
	// любой посредник, читающий и записывающий JSON.
	var container Signed
	if err := json.Unmarshal(signed, &container); err != nil {
		t.Fatalf("разобрать: %v", err)
	}
	repacked, err := json.Marshal(container)
	if err != nil {
		t.Fatalf("собрать: %v", err)
	}
	if _, err := Verify(repacked, pub); err != nil {
		t.Fatalf("пересобранный контейнер не прошёл проверку: %v", err)
	}
}
