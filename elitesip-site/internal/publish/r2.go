// Package publish — куда панель кладёт то, что читают машины.
package publish

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
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

// Пределы на читаемое. Панель забирает из бакета только свои же отметки —
// сотни байт, — и предел стоит затем, чтобы подменённый объект не смог
// вытеснить её память.
const (
	maxObjectSize = 1 << 20
	maxListSize   = 8 << 20
)

// ErrNoObject — объекта в бакете нет.
//
// Отдельной ошибкой, потому что для разбора отметок это обычное состояние, а
// не сбой: отметку мог унести срок жизни объектов.
var ErrNoObject = errors.New("объекта нет в бакете")

// Put кладёт объект.
func (r *R2) Put(ctx context.Context, objectKey string, data []byte) error {
	resp, err := r.do(ctx, http.MethodPut, objectKey, nil, data)
	if err != nil {
		return fmt.Errorf("выложить %s: %w", objectKey, err)
	}
	defer resp.Body.Close()

	if err := statusError(resp); err != nil {
		return fmt.Errorf("выложить %s: %w", objectKey, err)
	}
	return nil
}

// Delete уносит объект.
//
// Отсутствие объекта — не ошибка: уборка идёт от базы к бакету и повторяется по
// расписанию, а значит регулярно попадает на то, что уже унесли. Отказ здесь
// означал бы ошибку в журнале панели при каждом заходе.
func (r *R2) Delete(ctx context.Context, objectKey string) error {
	resp, err := r.do(ctx, http.MethodDelete, objectKey, nil, nil)
	if err != nil {
		return fmt.Errorf("унести %s: %w", objectKey, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if err := statusError(resp); err != nil {
		return fmt.Errorf("унести %s: %w", objectKey, err)
	}
	return nil
}

// Get читает объект.
//
// Нужен, чтобы забирать отметки, которые оставляет Worker: панель ходит в
// бакет и так, и второй канал с отдельным секретом ради того же самого был бы
// вторым местом, где можно ошибиться с доступом.
func (r *R2) Get(ctx context.Context, objectKey string) ([]byte, error) {
	resp, err := r.do(ctx, http.MethodGet, objectKey, nil, nil)
	if err != nil {
		return nil, fmt.Errorf("прочитать %s: %w", objectKey, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrNoObject
	}
	if err := statusError(resp); err != nil {
		return nil, fmt.Errorf("прочитать %s: %w", objectKey, err)
	}

	// Отметки Worker'а — сотни байт. Предел стоит затем, чтобы подменённый
	// объект не смог вытеснить память панели.
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxObjectSize))
	if err != nil {
		return nil, fmt.Errorf("прочитать %s: %w", objectKey, err)
	}
	return data, nil
}

// List перечисляет имена объектов с этой приставкой.
//
// Постранично: у S3 ответ обрезан тысячей имён, и без продолжения панель
// однажды перестала бы видеть машины, номера которых оказались за границей.
func (r *R2) List(ctx context.Context, prefix string) ([]string, error) {
	var (
		out   []string
		token string
	)
	for {
		query := url.Values{
			"list-type": {"2"},
			"prefix":    {prefix},
		}
		if token != "" {
			query.Set("continuation-token", token)
		}

		resp, err := r.do(ctx, http.MethodGet, "", query, nil)
		if err != nil {
			return nil, fmt.Errorf("перечислить %s*: %w", prefix, err)
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxListSize))
		resp.Body.Close()
		if err := statusError2(resp, body); err != nil {
			return nil, fmt.Errorf("перечислить %s*: %w", prefix, err)
		}
		if readErr != nil {
			return nil, fmt.Errorf("перечислить %s*: %w", prefix, readErr)
		}

		var listing struct {
			Contents []struct {
				Key string `xml:"Key"`
			} `xml:"Contents"`
			IsTruncated           bool   `xml:"IsTruncated"`
			NextContinuationToken string `xml:"NextContinuationToken"`
		}
		if err := xml.Unmarshal(body, &listing); err != nil {
			return nil, fmt.Errorf("разобрать перечень %s*: %w", prefix, err)
		}
		for _, item := range listing.Contents {
			out = append(out, item.Key)
		}

		if !listing.IsTruncated || listing.NextContinuationToken == "" {
			return out, nil
		}
		token = listing.NextContinuationToken
	}
}

// do собирает, подписывает и отправляет запрос.
//
// Один путь на все три действия: подпись — то место, где расхождение между
// «как собрали» и «как подписали» ловится не тестом, а отказом бакета в бою.
func (r *R2) do(ctx context.Context, method, objectKey string, query url.Values, body []byte) (*http.Response, error) {
	endpoint := strings.TrimRight(r.Endpoint, "/")
	target := endpoint + "/" + r.Bucket
	if objectKey != "" {
		target += "/" + objectKey
	}

	parsed, err := url.Parse(target)
	if err != nil {
		return nil, fmt.Errorf("разобрать адрес бакета %q: %w", target, err)
	}
	if len(query) > 0 {
		// Encode сортирует по имени — ровно то, чего требует канонический
		// запрос SigV4. Своя сборка строки здесь однажды разошлась бы с ним.
		parsed.RawQuery = query.Encode()
	}

	req, err := http.NewRequestWithContext(ctx, method, parsed.String(), bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("собрать запрос: %w", err)
	}
	req.ContentLength = int64(len(body))
	if method == http.MethodPut {
		req.Header.Set("Content-Type", "application/json")
	}

	if err := r.sign(req, body); err != nil {
		return nil, err
	}

	resp, err := r.client().Do(req)
	if err != nil {
		return nil, err
	}
	return resp, nil
}

// statusError превращает отказ бакета в ошибку с причиной.
//
// Тело ответа S3 — это XML с причиной, и без него разбирать «403» можно
// только гаданием.
func statusError(resp *http.Response) error {
	if resp.StatusCode >= 200 && resp.StatusCode <= 299 {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return statusError2(resp, body)
}

func statusError2(resp *http.Response, body []byte) error {
	if resp.StatusCode >= 200 && resp.StatusCode <= 299 {
		return nil
	}
	return fmt.Errorf("бакет ответил %s: %s", resp.Status, strings.TrimSpace(string(body)))
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
