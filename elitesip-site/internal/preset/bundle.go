package preset

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// BundleFormat — версия файла предустановок.
const BundleFormat = 1

// Bundle — файл, который лежит на R2 и который тянут все рабочие места.
//
// Один файл на все предустановки, а не по файлу на каждую: машина не должна
// знать, сколько их всего, а панель — держать список объектов в бакете в
// согласии с базой. Лишний десяток килобайт раз в полчаса дешевле рассинхрона.
type Bundle struct {
	Format      int       `json:"format"`
	GeneratedAt time.Time `json:"generated_at"`
	Presets     []Entry   `json:"presets"`
}

// Entry — одна предустановка в файле.
type Entry struct {
	// ID — то, по чему машина находит себя. Совпадает с тем, что приехало в
	// пакете активации.
	ID string `json:"id"`

	// Name показывается администратору на машине. Переименование имени не
	// разрывает связь: связь держит ID.
	Name string `json:"name"`

	Revision      int `json:"revision"`
	SchemaVersion int `json:"schema_version"`

	Fields json.RawMessage `json:"fields"`
}

// Signed — то, что физически лежит в бакете.
//
// Подпись считается по байтам payload, а payload лежит рядом как есть. Так
// проверка не зависит ни от канонизации JSON, ни от того, как чужой разбор
// переставит ключи: подписано ровно то, что прочитано.
type Signed struct {
	Payload   []byte `json:"payload"`
	Signature []byte `json:"signature"`
}

// ErrBadSignature — подпись не сходится.
//
// Ответ один на все случаи — подделка, чужой ключ, обрезанный файл: машине
// нечего с ними делать по-разному, а подробность помогала бы только тому, кто
// подбирает.
var ErrBadSignature = errors.New("подпись файла предустановок не сходится")

// Sign собирает подписанный файл.
func Sign(bundle Bundle, key ed25519.PrivateKey) ([]byte, error) {
	payload, err := json.Marshal(bundle)
	if err != nil {
		return nil, fmt.Errorf("собрать файл предустановок: %w", err)
	}
	return SignRaw(payload, key)
}

// SignRaw заворачивает готовые байты в тот же конверт.
//
// Нужен помашинным объектам — доступу и отзыву: они не файл предустановок, но
// проверяются приложением тем же способом и тем же ключом. Заводить им второй
// конверт значило бы завести и вторую проверку подписи в приложении, то есть
// второе место, где её можно однажды не сделать.
func SignRaw(payload []byte, key ed25519.PrivateKey) ([]byte, error) {
	if len(key) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("ключ подписи неверной длины: %d", len(key))
	}

	signed, err := json.Marshal(Signed{
		Payload:   payload,
		Signature: ed25519.Sign(key, payload),
	})
	if err != nil {
		return nil, fmt.Errorf("подписать: %w", err)
	}
	return signed, nil
}

// Verify проверяет подпись и разбирает файл.
//
// Живёт рядом с Sign не ради приложения — оно на Swift и проверяет само, — а
// ради проверки: обе половины должны сходиться, и убедиться в этом можно
// только тестом.
func Verify(data []byte, pub ed25519.PublicKey) (Bundle, error) {
	if len(pub) != ed25519.PublicKeySize {
		return Bundle{}, fmt.Errorf("открытый ключ неверной длины: %d", len(pub))
	}

	var signed Signed
	if err := json.Unmarshal(data, &signed); err != nil {
		return Bundle{}, fmt.Errorf("разобрать подписанный файл: %w", err)
	}
	if !ed25519.Verify(pub, signed.Payload, signed.Signature) {
		return Bundle{}, ErrBadSignature
	}

	var bundle Bundle
	if err := json.Unmarshal(signed.Payload, &bundle); err != nil {
		return Bundle{}, fmt.Errorf("разобрать файл предустановок: %w", err)
	}
	if bundle.Format != BundleFormat {
		// Отдельная беда с отдельным сообщением: файл целый и подпись сошлась,
		// просто он новее этой стороны.
		return Bundle{}, fmt.Errorf(
			"файл предустановок версии %d, эта сторона знает %d", bundle.Format, BundleFormat)
	}
	return bundle, nil
}
