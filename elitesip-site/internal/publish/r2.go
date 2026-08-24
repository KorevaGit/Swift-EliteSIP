// Package publish — куда панель кладёт то, что читают машины.
package publish

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// R2 кладёт объекты в бакет Cloudflare R2 по протоколу S3.
//
// Своя подпись, а не готовый SDK. Довод тот же, по которому Tools/release.sh
// выкладывает выпуски через `curl --aws-sigv4`: SigV4 — это сотня строк и один
// раз, а SDK — дерево зависимостей, которое надо обновлять на сервере, куда
// никто не смотрит месяцами.
type R2 struct {
	// Endpoint — адрес вида https://<счёт>.r2.cloudflarestorage.com
	Endpoint string
	Bucket   string

	AccessKeyID     string
	SecretAccessKey string

	// Client подменяется в проверках.
	Client *http.Client

	// Now подменяется в проверках: подпись зависит от времени.
	Now func() time.Time
}

// region — у R2 регион всегда `auto`, но в подпись он входить обязан.
const region = "auto"

// Put кладёт объект.
func (r *R2) Put(ctx context.Context, objectKey string, data []byte) error {
	endpoint := strings.TrimRight(r.Endpoint, "/")
	target := fmt.Sprintf("%s/%s/%s", endpoint, r.Bucket, objectKey)

	parsed, err := url.Parse(target)
	if err != nil {
		return fmt.Errorf("разобрать адрес бакета %q: %w", target, err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPut, parsed.String(), bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("собрать запрос на выкладку: %w", err)
	}
	req.ContentLength = int64(len(data))
	req.Header.Set("Content-Type", "application/json")

	if err := r.sign(req, data); err != nil {
		return err
	}

	resp, err := r.client().Do(req)
	if err != nil {
		return fmt.Errorf("выложить %s: %w", objectKey, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		// Тело ответа S3 — это XML с причиной отказа, и без него разбирать
		// «403» можно только гаданием.
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("выложить %s: бакет ответил %s: %s",
			objectKey, resp.Status, strings.TrimSpace(string(body)))
	}
	return nil
}

// sign подписывает запрос по AWS Signature Version 4.
func (r *R2) sign(req *http.Request, body []byte) error {
	now := r.now().UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")

	payloadHash := sha256hex(body)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", payloadHash)
	req.Header.Set("Host", req.URL.Host)

	// Подписываются ровно три заголовка. Больше — значит больше поводов
	// разойтись с тем, что реально уйдёт в сеть: транспорт добавляет свои, и
	// каждый добавленный в подпись становится обязательством.
	signedHeaders := "host;x-amz-content-sha256;x-amz-date"
	canonicalHeaders := strings.Join([]string{
		"host:" + req.URL.Host,
		"x-amz-content-sha256:" + payloadHash,
		"x-amz-date:" + amzDate,
	}, "\n") + "\n"

	canonicalRequest := strings.Join([]string{
		req.Method,
		escapePath(req.URL.Path),
		req.URL.RawQuery,
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	}, "\n")

	scope := strings.Join([]string{dateStamp, region, "s3", "aws4_request"}, "/")
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		sha256hex([]byte(canonicalRequest)),
	}, "\n")

	key := hmacSum([]byte("AWS4"+r.SecretAccessKey), dateStamp)
	key = hmacSum(key, region)
	key = hmacSum(key, "s3")
	key = hmacSum(key, "aws4_request")
	signature := hex.EncodeToString(hmacSum(key, stringToSign))

	req.Header.Set("Authorization", fmt.Sprintf(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		r.AccessKeyID, scope, signedHeaders, signature))
	return nil
}

// escapePath кодирует путь так, как того требует SigV4.
//
// url.PathEscape здесь не годится: он экранирует косую черту, а она в пути
// объекта разделитель. А вот пробел обязан стать %20, а не плюсом.
func escapePath(path string) string {
	segments := strings.Split(path, "/")
	for i, segment := range segments {
		segments[i] = strings.ReplaceAll(url.QueryEscape(segment), "+", "%20")
	}
	return strings.Join(segments, "/")
}

func sha256hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func hmacSum(key []byte, data string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(data))
	return mac.Sum(nil)
}

func (r *R2) client() *http.Client {
	if r.Client != nil {
		return r.Client
	}
	// Свой клиент со сроком: выкладка идёт из обработчика запроса панели, и
	// зависший бакет не должен держать её вечно.
	return &http.Client{Timeout: 30 * time.Second}
}

func (r *R2) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}
