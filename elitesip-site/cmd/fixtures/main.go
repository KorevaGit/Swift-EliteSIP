// Команда fixtures печатает образцы для тестов приложения.
//
// Тесты Swift-пакета PanelLink открывают пакет активации и проверяют подпись
// файла предустановок на том, что собрала **эта** панель, а не на собранном
// рядом своим же кодом. Своё проверяло бы только то, что мы согласны сами с
// собой; разойдутся стороны — разойдётся в тесте, а не на живой машине.
//
// Поэтому образцы не выдуманы, а выпущены отсюда — и перевыпускаются отсюда же,
// когда меняется формат:
//
//	go run ./cmd/fixtures
//
// Печатаемое вставляется в Packages/PanelLink/Tests/PanelLinkTests.
package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/activation"
	"github.com/koreva/elitesip-site/internal/panel"
	"github.com/koreva/elitesip-site/internal/preset"
)

func main() {
	activationFixture()
	fmt.Println()
	bundleFixture()
	fmt.Println()
	machineFixtures()
}

// activationFixture — пакет активации под ActivationTests.swift.
//
// Ключ постоянный, а не случайный: тест сверяет ещё и выведенный из него адрес
// пакета, и случайный ключ пришлось бы переписывать при каждом запуске.
func activationFixture() {
	key := activation.Key("K7M29XQP4TFB")

	payload := activation.Payload{
		Format:         activation.PayloadFormat,
		InstallationID: "8f2c4a1b9d3e5f60",
		Employee:       "Пётр Смирнов",
		Number:         "172",
		SIPPassword:    "s3cret-172",
		// Ключ канала в образце постоянный по той же причине, что и сам ключ:
		// случайный пришлось бы переписывать в тесте при каждом запуске.
		ChannelKey: "0123456789abcdef0123456789abcdef" +
			"0123456789abcdef0123456789abcdef",
		Preset: activation.PresetPayload{
			ID:            "6D1F5A20-0000-4000-8000-000000000001",
			Name:          "Менеджер",
			Revision:      7,
			SchemaVersion: 2,
			Settings: json.RawMessage(
				`{"dtmf":{"toneMilliseconds":120,"macros":[` +
					`{"id":"a","title":"ЮРИСТ","sequence":"*02,101","transfersCall":true}]}}`),
		},
	}

	plaintext, err := json.Marshal(payload)
	if err != nil {
		panic(err)
	}
	bound, err := activation.Bind(key, "")
	if err != nil {
		panic(err)
	}
	sealed, err := bound.Seal(plaintext)
	if err != nil {
		panic(err)
	}

	fmt.Println("=== пакет активации ===")
	fmt.Println("ключ:  ", key.String())
	fmt.Println("адрес: ", bound.ObjectKey())
	fmt.Println("пакет: ", base64.StdEncoding.EncodeToString(sealed))
}

// bundleFixture — подписанный файл предустановок под PresetBundleTests.swift.
//
// Ключ подписи выведен из постоянного зерна по той же причине: образец обязан
// быть воспроизводимым. Настоящий ключ линии сюда не попадает и попасть не
// может — он лежит файлом на офисном сервере.
func bundleFixture() {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	private := ed25519.NewKeyFromSeed(seed)

	bundle := preset.Bundle{
		Format:      preset.BundleFormat,
		GeneratedAt: time.Date(2026, 8, 24, 15, 30, 0, 0, time.UTC),
		Presets: []preset.Entry{{
			ID:            "6D1F5A20-0000-4000-8000-000000000001",
			Name:          "Менеджер",
			Revision:      12,
			SchemaVersion: 2,
			Fields: json.RawMessage(
				`{"siteAddresses":{"office":"192.168.1.2","remote":"crm.elitesochi.com"}}`),
		}},
	}

	signed, err := preset.Sign(bundle, private)
	if err != nil {
		panic(err)
	}

	fmt.Println("=== файл предустановок ===")
	fmt.Println("открытый ключ:", base64.StdEncoding.EncodeToString(private.Public().(ed25519.PublicKey)))
	fmt.Println("файл:         ", base64.StdEncoding.EncodeToString(signed))
}

// machineFixtures — помашинные объекты под MachineObjectTests.swift.
//
// Собираются той же дорогой, что и в бою: панелью, её конвертом, её ключом.
// Сочинённый здесь же образец проверял бы только то, что мы согласны сами с
// собой.
func machineFixtures() {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	private := ed25519.NewKeyFromSeed(seed)

	store := &memorySink{objects: map[string][]byte{}}
	writer := &panel.MachineWriter{
		Publisher:  store,
		SigningKey: private,
		Now:        func() time.Time { return time.Date(2026, 8, 25, 12, 0, 0, 0, time.UTC) },
	}

	const machine = "8f2c4a1b9d3e5f60"
	ctx := context.Background()
	if err := writer.Access(ctx, machine, "6D1F5A20-0000-4000-8000-000000000001", "пароль-предустановки"); err != nil {
		panic(err)
	}
	if err := writer.Revoke(ctx, machine); err != nil {
		panic(err)
	}

	fmt.Println("=== помашинные объекты ===")
	fmt.Println("машина: ", machine)
	fmt.Println("доступ: ", base64.StdEncoding.EncodeToString(store.objects["access/"+machine]))
	fmt.Println("отзыв:  ", base64.StdEncoding.EncodeToString(store.objects["revoked/"+machine]))
}

type memorySink struct{ objects map[string][]byte }

func (m *memorySink) Put(_ context.Context, key string, data []byte) error {
	m.objects[key] = data
	return nil
}
