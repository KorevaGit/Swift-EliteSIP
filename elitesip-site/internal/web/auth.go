package web

import (
	"errors"
	"net/http"
	"strings"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/panel"
	"github.com/koreva/elitesip-site/internal/storage"
)

func (s *Server) showLogin(w http.ResponseWriter, r *http.Request) {
	count, err := s.DB.AdminCount(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	if count == 0 {
		http.Redirect(w, r, "/setup", http.StatusSeeOther)
		return
	}
	s.render(w, r, "login", page{Title: "Вход", Data: r.URL.Query().Get("err")})
}

func (s *Server) doLogin(w http.ResponseWriter, r *http.Request) {
	if !s.checkCSRF(r) {
		s.rejectCSRF(w)
		return
	}

	login := strings.TrimSpace(r.FormValue("login"))
	password := r.FormValue("password")

	admin, err := s.DB.AdminByLogin(r.Context(), login)
	if err == nil && admin.Active() {
		err = panel.CheckPassword(admin.PasswordHash, password)
	} else if err == nil {
		err = storage.ErrDisabled
	}

	if err != nil {
		// Один ответ на все случаи — нет такого имени, неверный пароль,
		// отключён: подбирающему незачем знать, какое из имён существует.
		s.render(w, r, "login", page{
			Title: "Вход",
			Data:  "Неверное имя или пароль",
		})
		return
	}

	token, err := s.DB.StartSession(r.Context(), admin.ID)
	if err != nil {
		s.fail(w, err)
		return
	}
	http.SetCookie(w, sessionCookieFor(token))
	http.Redirect(w, r, "/employees", http.StatusSeeOther)
}

func (s *Server) doLogout(w http.ResponseWriter, r *http.Request) {
	if !s.checkCSRF(r) {
		s.rejectCSRF(w)
		return
	}
	if cookie, err := r.Cookie(sessionCookie); err == nil {
		s.DB.EndSession(r.Context(), cookie.Value)
	}
	http.SetCookie(w, expiredCookie())
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// showSetup — заведение первого администратора.
//
// Открыт без пароля, но только пока администраторов нет вовсе. Иначе это была
// бы дверь, через которую в панель входит кто угодно из офисной сети.
func (s *Server) showSetup(w http.ResponseWriter, r *http.Request) {
	count, err := s.DB.AdminCount(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	if count > 0 {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}
	s.render(w, r, "setup", page{Title: "Первый администратор"})
}

func (s *Server) doSetup(w http.ResponseWriter, r *http.Request) {
	count, err := s.DB.AdminCount(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	if count > 0 {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}
	if !s.checkCSRF(r) {
		s.rejectCSRF(w)
		return
	}

	login := strings.TrimSpace(r.FormValue("login"))
	password := r.FormValue("password")

	if login == "" || len(password) < 8 {
		s.render(w, r, "setup", page{
			Title: "Первый администратор",
			Data:  "Нужны имя и пароль не короче восьми знаков",
		})
		return
	}

	hash, err := panel.HashPassword(password)
	if err != nil {
		s.render(w, r, "setup", page{Title: "Первый администратор", Data: err.Error()})
		return
	}

	admin, err := s.DB.CreateAdmin(r.Context(), nil, login, hash)
	if err != nil {
		s.render(w, r, "setup", page{Title: "Первый администратор", Data: err.Error()})
		return
	}

	token, err := s.DB.StartSession(r.Context(), admin.ID)
	if err != nil {
		s.fail(w, err)
		return
	}
	http.SetCookie(w, sessionCookieFor(token))
	s.flashTo(token, "warn", "Панель готова",
		"Задайте административный пароль конторы в настройках — без него ключи не выпускаются.")
	http.Redirect(w, r, "/settings", http.StatusSeeOther)
}

// actorOf — кто совершает действие. Уходит в журнал.
func actorOf(admin model.Admin) *int64 {
	id := admin.ID
	return &id
}

// friendly превращает ошибку хранилища в то, что можно показать человеку.
func friendly(err error) string {
	switch {
	case errors.Is(err, storage.ErrNotFound):
		return "Запись не найдена — возможно, её только что удалили в соседнем окне"
	case errors.Is(err, storage.ErrNumberTaken):
		return "Этот номер уже закреплён за другим сотрудником"
	case errors.Is(err, storage.ErrNoNumber):
		return "У сотрудника не заполнены номер и SIP-пароль"
	case errors.Is(err, storage.ErrNoPreset):
		return "У сотрудника нет предустановки с сохранённой ревизией"
	default:
		return err.Error()
	}
}
