// Package config — как панель настраивается при запуске.
package config

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strings"
)

// Config — всё, что панель узнаёт снаружи.
//
// Из переменных окружения, а не из своего файла настроек: панель ставится
// докером с компоузом, и второй формат настройки рядом с compose-файлом
// означал бы два места, где что-то может разойтись.
//
// Секреты при этом приходят **путями к файлам**, а не значениями. Значение в
// переменной окружения видно в `docker inspect`, в списке процессов и в
// логах падения; файл с правами 600 — нет.
type Config struct {
	Listen string
	DBPath string

	SigningKeyFile string
	SecretFile     string

	R2Endpoint  string
	R2Bucket    string
	R2AccessKey string
	R2Secret    string

	// PublishDir — выкладка в каталог вместо R2. Для стенда.
	PublishDir string
}

// Load собирает настройки из окружения.
func Load() (Config, error) {
	c := Config{
		Listen:         env("ELITESIP_LISTEN", "127.0.0.1:8080"),
		DBPath:         env("ELITESIP_DB", "/var/lib/elitesip/panel.db"),
		SigningKeyFile: env("ELITESIP_SIGNING_KEY_FILE", "/var/lib/elitesip/signing.key"),
		SecretFile:     env("ELITESIP_SECRET_FILE", "/var/lib/elitesip/server.secret"),
		R2Endpoint:     os.Getenv("ELITESIP_R2_ENDPOINT"),
		R2Bucket:       os.Getenv("ELITESIP_R2_BUCKET"),
		R2AccessKey:    os.Getenv("ELITESIP_R2_ACCESS_KEY_ID"),
		R2Secret:       os.Getenv("ELITESIP_R2_SECRET_ACCESS_KEY"),
		PublishDir:     os.Getenv("ELITESIP_PUBLISH_DIR"),
	}

	if c.PublishDir == "" && c.R2Bucket == "" {
		return Config{}, errors.New(
			"не задано, куда выкладывать: нужен ELITESIP_R2_BUCKET или ELITESIP_PUBLISH_DIR")
	}
	if c.R2Bucket != "" {
		for name, value := range map[string]string{
			"ELITESIP_R2_ENDPOINT":          c.R2Endpoint,
			"ELITESIP_R2_ACCESS_KEY_ID":     c.R2AccessKey,
			"ELITESIP_R2_SECRET_ACCESS_KEY": c.R2Secret,
		} {
			if value == "" {
				return Config{}, fmt.Errorf("задан бакет, но не задано %s", name)
			}
		}
	}
	return c, nil
}

// LoadSigningKey читает приватный ключ линии предустановок.
//
// В файле лежит семя (32 байта) в base64, а не полный приватный ключ: так
// строка короче, а восстановить из семени можно и приватный, и открытый — то
// есть потерять открытый ключ отдельно невозможно.
func LoadSigningKey(path string) (ed25519.PrivateKey, error) {
	raw, err := readSecretFile(path)
	if err != nil {
		return nil, err
	}

	seed, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("ключ подписи %s не читается как base64: %w", path, err)
	}
	if len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("ключ подписи %s длиной %d байт, ожидалось %d",
			path, len(seed), ed25519.SeedSize)
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

// LoadSecret читает секрет сервера для отпечатков ключей.
func LoadSecret(path string) ([]byte, error) {
	raw, err := readSecretFile(path)
	if err != nil {
		return nil, err
	}
	secret, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("секрет %s не читается как base64: %w", path, err)
	}
	if len(secret) < 32 {
		return nil, fmt.Errorf("секрет %s короче 32 байт", path)
	}
	return secret, nil
}

func readSecretFile(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("прочитать %s: %w", path, err)
	}

	// Права проверяются, а не исправляются: молча сузить права значило бы
	// скрыть, что файл какое-то время лежал открытым, — а это уже случившееся
	// событие, о котором должен знать человек.
	if mode := info.Mode().Perm(); mode&0o077 != 0 {
		return "", fmt.Errorf(
			"%s доступен не только владельцу (права %04o) — секрету это не подходит", path, mode)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("прочитать %s: %w", path, err)
	}
	return strings.TrimSpace(string(data)), nil
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
