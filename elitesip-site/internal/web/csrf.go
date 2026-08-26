package web

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
)

// csrfCookie — предварительная кука для форм входа и первого администратора:
// у них ещё нет сеанса, за который можно зацепить токен.
const csrfCookie = "elitesip_csrf"

// csrfField — имя скрытого поля во всех формах панели.
const csrfField = "csrf"

// csrfToken — HMAC значения на секрете сервера, hex.
//
// Токен не хранится нигде: он выводится заново из того же значения (токена
// сессии или предварительной куки) и на входе формы, и при проверке. Домен
// "csrf:" отделяет его от отпечатков ключей, которые считаются тем же
// секретом в internal/panel — разные названия, одно значение секрета, разные
// входы: смешать их местами всё равно не получится.
func (s *Server) csrfToken(value string) string {
	mac := hmac.New(sha256.New, s.CSRFSecret)
	mac.Write([]byte("csrf:"))
	mac.Write([]byte(value))
	return hex.EncodeToString(mac.Sum(nil))
}

// checkCSRF сверяет токен формы с тем, что ожидается от текущего запроса.
//
// Вошедший пользователь несёт токен от куки сеанса. У форм входа и первого
// администратора сеанса ещё нет — токен у них от отдельной предварительной
// куки, которую выдаёт showLogin/showSetup через render. Проверяется то же
// значение, что и выводилось: подмены сеанса на предварительную куку и
// наоборот не бывает, потому что токены от разных значений не совпадут.
func (s *Server) checkCSRF(r *http.Request) bool {
	var value string
	if cookie, err := r.Cookie(sessionCookie); err == nil {
		value = cookie.Value
	} else if cookie, err := r.Cookie(csrfCookie); err == nil {
		value = cookie.Value
	} else {
		return false
	}
	if value == "" {
		return false
	}

	want := s.csrfToken(value)
	got := r.FormValue(csrfField)
	return got != "" && subtle.ConstantTimeCompare([]byte(want), []byte(got)) == 1
}

// ensureCSRFCookie выдаёт предварительную CSRF-куку, если её ещё нет, и
// возвращает токен для скрытого поля формы. Вызывается из render для страниц
// без сеанса — /login и /setup.
func (s *Server) ensureCSRFCookie(w http.ResponseWriter, r *http.Request) string {
	if cookie, err := r.Cookie(csrfCookie); err == nil && cookie.Value != "" {
		return s.csrfToken(cookie.Value)
	}

	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		// Практически недостижимо — источник случайности не в этом процессе
		// не читается. Пустой токен просто провалит следующую проверку.
		return ""
	}
	value := hex.EncodeToString(raw)
	http.SetCookie(w, &http.Cookie{
		Name:     csrfCookie,
		Value:    value,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	return s.csrfToken(value)
}

// rejectCSRF — единственный отказ на пропавший или устаревший токен формы.
//
// Простой текст, а не собранная страница: страницы уже требуют токен сами по
// себе, а собирать шаблон для отказа в токене — заворачивать проверку в то же,
// что она проверяет.
func (s *Server) rejectCSRF(w http.ResponseWriter) {
	http.Error(w, "форма устарела — обновите страницу и попробуйте снова", http.StatusForbidden)
}
