package web

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/koreva/elitesip-site/internal/activation"
	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/storage"
)

// findByKey ищет активацию по ключу, который прислал сотрудник.
//
// Существует ради одного разговора: «ввожу ключ K7M2-…, не работает». Панель
// ключей не хранит — она хранит отпечаток, HMAC с серверным секретом, — и
// сравнить можно только пересчитав отпечаток от введённого. Поэтому поиск
// точный и единственно возможный: похожие ключи здесь не ищутся никак.
//
// Опознание по key_prefix для этого не годится: четыре знака не уникальны, и
// при тридцати сотрудниках с тремя ключами совпадение — вопрос времени.
func (s *Server) findByKey(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	raw := r.FormValue("key")

	key, err := activation.Parse(raw)
	if err != nil {
		// Разбор терпимый — буквы и цифры, остальное выбрасывается, — поэтому
		// сюда попадает только то, что на ключ не похоже вовсе.
		s.flash(r, "bad", "Это не ключ", "Ключ — двенадцать знаков, обычно тремя группами по четыре.")
		s.back(w, r, "/employees")
		return
	}

	found, err := s.DB.ActivationByFingerprint(r.Context(),
		activation.Fingerprint(s.Issuer.Secret, key))
	if errors.Is(err, storage.ErrNotFound) {
		// Отвечаем прямо. Круг лиц свой, а при шестидесяти битах оракул
		// «существует ли такой ключ» не даёт подбирающему ничего.
		s.flash(r, "warn", "Такого ключа нет",
			"Ни одной активации с этим ключом панель не выпускала. Проверьте, тот ли ключ прислали.")
		s.back(w, r, "/employees")
		return
	}
	if err != nil {
		s.fail(w, err)
		return
	}

	// Перекидываем на карточку сотрудника, а не показываем выжимку отдельной
	// страницей: одно место правды вместо двух похожих экранов.
	http.Redirect(w, r,
		"/employees/"+strconv.FormatInt(found.EmployeeID, 10)+
			"?found="+strconv.FormatInt(found.ID, 10)+
			"#activation-"+strconv.FormatInt(found.ID, 10),
		http.StatusSeeOther)
}

// highlightFrom — какую строку подсветить на карточке.
func highlightFrom(r *http.Request) int64 {
	id, err := strconv.ParseInt(r.URL.Query().Get("found"), 10, 64)
	if err != nil {
		return 0
	}
	return id
}

// reflashMachine выпускает ключ перепрошивки для работающей машины.
//
// Смена отдела перестаёт означать выезд к машине: предустановка, номер,
// SIP-пароль и административный пароль приезжают новым пакетом, а
// installation_id остаётся прежним — иначе панель увидела бы смерть одной
// машины и рождение другой, а история отметок разорвалась бы надвое.
func (s *Server) reflashMachine(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	installationID := r.PathValue("installation")
	if installationID == "" {
		http.NotFound(w, r)
		return
	}

	key, saved, err := s.Issuer.Reflash(r.Context(), actorOf(admin), installationID, r.FormValue("note"))
	if err != nil {
		s.flash(r, "bad", "Ключ перепрошивки не выпущен", friendly(err))
		s.back(w, r, "/employees")
		return
	}

	name := ""
	if employee, err := s.DB.EmployeeByID(r.Context(), saved.EmployeeID); err == nil {
		name = employee.Name
	}
	link, _ := s.DB.Setting(r.Context(), storage.SettingAppLink)

	s.flashKey(r, key.String(),
		reflashMessage(name, key.String(), saved.ExpiresAt, link),
		"Ключ сработает только на этой машине. Сотрудник вводит его в «Техподдержке»; "+
			"применится, когда он положит трубку.")
	http.Redirect(w, r, "/employees/"+strconv.FormatInt(saved.EmployeeID, 10), http.StatusSeeOther)
}
