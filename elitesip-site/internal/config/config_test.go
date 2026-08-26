package config

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeSecret(t *testing.T, name, content string, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatalf("записать %s: %v", name, err)
	}
	return path
}

func TestLoadNeedsSomewhereToPublish(t *testing.T) {
	t.Setenv("ELITESIP_R2_BUCKET", "")
	t.Setenv("ELITESIP_PUBLISH_DIR", "")

	if _, err := Load(); err == nil {
		t.Fatal("панель настроилась, не зная, куда выкладывать")
	}
}

// Половина настроек R2 хуже их отсутствия: панель поднимется и упадёт на
// первой же выкладке, то есть в тот момент, когда её ждут.
func TestLoadRejectsHalfConfiguredBucket(t *testing.T) {
	t.Setenv("ELITESIP_R2_BUCKET", "elitesip-panel")
	t.Setenv("ELITESIP_R2_ENDPOINT", "https://example.r2.cloudflarestorage.com")
	t.Setenv("ELITESIP_R2_ACCESS_KEY_ID", "")
	t.Setenv("ELITESIP_R2_SECRET_ACCESS_KEY", "секрет")

	_, err := Load()
	if err == nil {
		t.Fatal("бакет без ключа доступа принят")
	}
	if !strings.Contains(err.Error(), "ELITESIP_R2_ACCESS_KEY_ID") {
		t.Errorf("не сказано, чего не хватает: %v", err)
	}
}

func TestLoadAcceptsDirectoryPublishing(t *testing.T) {
	t.Setenv("ELITESIP_R2_BUCKET", "")
	t.Setenv("ELITESIP_PUBLISH_DIR", "/tmp/elitesip-stand")
	t.Setenv("ELITESIP_DB", "/srv/elitesip/data/panel.db")

	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Listen != "127.0.0.1:8080" {
		t.Errorf("умолчание адреса: %q", c.Listen)
	}
	if c.SandDBPath != "/srv/elitesip/data/sand.db" {
		t.Errorf("база песочницы лежит не рядом с основной: %q", c.SandDBPath)
	}
}

func TestSigningKeyRoundTrip(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	path := writeSecret(t, "signing.key",
		base64.StdEncoding.EncodeToString(priv.Seed())+"\n", 0o600)

	loaded, err := LoadSigningKey(path)
	if err != nil {
		t.Fatalf("LoadSigningKey: %v", err)
	}
	if !loaded.Public().(ed25519.PublicKey).Equal(pub) {
		t.Error("из семени восстановился другой ключ")
	}
}

// Секрет, доступный не только владельцу, — это уже случившееся событие, а не
// мелкая небрежность.
func TestSecretsRequireTightPermissions(t *testing.T) {
	path := writeSecret(t, "server.secret",
		base64.StdEncoding.EncodeToString(make([]byte, 32)), 0o644)

	_, err := LoadSecret(path)
	if err == nil {
		t.Fatal("секрет с правами 644 принят")
	}
	if !strings.Contains(err.Error(), "0644") {
		t.Errorf("в сообщении нет прав: %v", err)
	}
}

func TestShortSecretRejected(t *testing.T) {
	path := writeSecret(t, "server.secret",
		base64.StdEncoding.EncodeToString([]byte("коротко")), 0o600)

	if _, err := LoadSecret(path); err == nil {
		t.Fatal("короткий секрет принят")
	}
}

func TestSigningKeyOfWrongLengthRejected(t *testing.T) {
	path := writeSecret(t, "signing.key",
		base64.StdEncoding.EncodeToString([]byte("не тридцать два байта")), 0o600)

	if _, err := LoadSigningKey(path); err == nil {
		t.Fatal("ключ неверной длины принят")
	}
}

func TestMissingSecretFileIsReported(t *testing.T) {
	_, err := LoadSecret(filepath.Join(t.TempDir(), "нет-такого"))
	if err == nil {
		t.Fatal("отсутствующий файл принят")
	}
}
