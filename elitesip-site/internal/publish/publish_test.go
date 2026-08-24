package publish

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixedClock() func() time.Time {
	moment := time.Date(2026, 8, 24, 15, 30, 0, 0, time.UTC)
	return func() time.Time { return moment }
}

// Проверяется форма запроса, а не совместимость с настоящим R2: сойдётся ли
// подпись с Cloudflare, показывает только живая выкладка, и это отдельный долг
// приёмки.
func TestPutSendsSignedRequest(t *testing.T) {
	var (
		gotMethod string
		gotPath   string
		gotBody   []byte
		gotAuth   string
		gotDigest string
		gotDate   string
	)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotBody = make([]byte, r.ContentLength)
		r.Body.Read(gotBody)
		gotAuth = r.Header.Get("Authorization")
		gotDigest = r.Header.Get("X-Amz-Content-Sha256")
		gotDate = r.Header.Get("X-Amz-Date")
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	r2 := &R2{
		Endpoint: server.URL, Bucket: "elitesip-panel",
		AccessKeyID: "ключ", SecretAccessKey: "секрет",
		Client: server.Client(), Now: fixedClock(),
	}

	body := []byte(`{"format":1}`)
	if err := r2.Put(context.Background(), "presets/current.json", body); err != nil {
		t.Fatalf("Put: %v", err)
	}

	if gotMethod != http.MethodPut {
		t.Errorf("метод %q", gotMethod)
	}
	if gotPath != "/elitesip-panel/presets/current.json" {
		t.Errorf("путь %q", gotPath)
	}
	if string(gotBody) != string(body) {
		t.Errorf("тело %q", gotBody)
	}

	sum := sha256.Sum256(body)
	if gotDigest != hex.EncodeToString(sum[:]) {
		t.Errorf("свёртка тела %q", gotDigest)
	}
	if gotDate != "20260824T153000Z" {
		t.Errorf("метка времени %q", gotDate)
	}

	for _, part := range []string{
		"AWS4-HMAC-SHA256",
		"Credential=ключ/20260824/auto/s3/aws4_request",
		"SignedHeaders=host;x-amz-content-sha256;x-amz-date",
		"Signature=",
	} {
		if !strings.Contains(gotAuth, part) {
			t.Errorf("в заголовке подписи нет %q: %s", part, gotAuth)
		}
	}
}

// Подпись обязана зависеть от тела: иначе перехваченный заголовок годился бы
// для любого содержимого.
func TestSignatureDependsOnBody(t *testing.T) {
	r2 := &R2{
		Endpoint: "https://example.r2.cloudflarestorage.com", Bucket: "b",
		AccessKeyID: "ключ", SecretAccessKey: "секрет", Now: fixedClock(),
	}

	first := signatureOf(t, r2, "presets/current.json", []byte("одно"))
	second := signatureOf(t, r2, "presets/current.json", []byte("другое"))
	third := signatureOf(t, r2, "presets/другое.json", []byte("одно"))

	if first == second {
		t.Error("подпись не зависит от тела")
	}
	if first == third {
		t.Error("подпись не зависит от имени объекта")
	}
}

func TestSignatureDependsOnTime(t *testing.T) {
	body := []byte("тело")
	early := &R2{Endpoint: "https://e.example", Bucket: "b", AccessKeyID: "k", SecretAccessKey: "s",
		Now: func() time.Time { return time.Date(2026, 8, 24, 10, 0, 0, 0, time.UTC) }}
	late := &R2{Endpoint: "https://e.example", Bucket: "b", AccessKeyID: "k", SecretAccessKey: "s",
		Now: func() time.Time { return time.Date(2026, 8, 24, 11, 0, 0, 0, time.UTC) }}

	if signatureOf(t, early, "o", body) == signatureOf(t, late, "o", body) {
		t.Error("подпись не зависит от времени")
	}
}

// Пробел в имени объекта обязан стать %20, а не плюсом: плюс S3 считает частью
// имени, и объект уляжется не туда.
func TestPathEscaping(t *testing.T) {
	cases := map[string]string{
		"/bucket/presets/current.json": "/bucket/presets/current.json",
		"/bucket/имя с пробелом":       "/bucket/%D0%B8%D0%BC%D1%8F%20%D1%81%20%D0%BF%D1%80%D0%BE%D0%B1%D0%B5%D0%BB%D0%BE%D0%BC",
		"/":                            "/",
	}
	for in, want := range cases {
		if got := escapePath(in); got != want {
			t.Errorf("escapePath(%q) = %q, ожидалось %q", in, got, want)
		}
	}
}

// Отказ бакета должен доезжать с телом ответа: без него разбирать «403» можно
// только гаданием.
func TestPutReportsBucketRefusal(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte("<Error><Code>SignatureDoesNotMatch</Code></Error>"))
	}))
	defer server.Close()

	r2 := &R2{Endpoint: server.URL, Bucket: "b", AccessKeyID: "k", SecretAccessKey: "s",
		Client: server.Client(), Now: fixedClock()}

	err := r2.Put(context.Background(), "presets/current.json", []byte("{}"))
	if err == nil {
		t.Fatal("отказ бакета прошёл незамеченным")
	}
	if !strings.Contains(err.Error(), "SignatureDoesNotMatch") {
		t.Errorf("причина отказа потеряна: %v", err)
	}
}

func TestDirPublisherWritesFile(t *testing.T) {
	root := t.TempDir()
	dir := Dir{Root: root}

	if err := dir.Put(context.Background(), "presets/current.json", []byte("содержимое")); err != nil {
		t.Fatalf("Put: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(root, "presets", "current.json"))
	if err != nil {
		t.Fatalf("прочитать: %v", err)
	}
	if string(got) != "содержимое" {
		t.Errorf("записано %q", got)
	}
}

func TestDirPublisherRefusesEscape(t *testing.T) {
	dir := Dir{Root: t.TempDir()}

	if err := dir.Put(context.Background(), "../наружу", []byte("нет")); err == nil {
		t.Fatal("запись за пределы каталога прошла")
	}
}

func signatureOf(t *testing.T, r2 *R2, objectKey string, body []byte) string {
	t.Helper()

	req, err := http.NewRequest(http.MethodPut,
		r2.Endpoint+"/"+r2.Bucket+"/"+objectKey, strings.NewReader(string(body)))
	if err != nil {
		t.Fatalf("собрать запрос: %v", err)
	}
	if err := r2.sign(req, body); err != nil {
		t.Fatalf("sign: %v", err)
	}
	return req.Header.Get("Authorization")
}
