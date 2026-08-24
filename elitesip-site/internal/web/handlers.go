package web

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/storage"
)

// ------------------------------------------------------------- сотрудники

type employeesData struct {
	Employees []storage.EmployeeCard
	Presets   []storage.PresetSummary
	ShowGone  bool
}

func (s *Server) showEmployees(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	showGone := r.URL.Query().Get("all") == "1"

	people, err := s.DB.ListEmployees(r.Context(), showGone)
	if err != nil {
		s.fail(w, err)
		return
	}
	presets, err := s.DB.ListPresets(r.Context(), false)
	if err != nil {
		s.fail(w, err)
		return
	}

	s.render(w, r, "employees", page{
		Title: "Сотрудники", Section: "employees", Admin: admin,
		Data: employeesData{Employees: people, Presets: presets, ShowGone: showGone},
	})
}

func (s *Server) createEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	name := strings.TrimSpace(r.FormValue("name"))
	if name == "" {
		s.flash(r, "bad", "Не заведён", "Имя сотрудника не может быть пустым")
		s.back(w, r, "/employees")
		return
	}

	var presetID *int64
	if raw := r.FormValue("preset_id"); raw != "" {
		if id, err := strconv.ParseInt(raw, 10, 64); err == nil {
			presetID = &id
		}
	}

	created, err := s.DB.CreateEmployee(r.Context(), actorOf(admin), name, presetID)
	if err != nil {
		s.flash(r, "bad", "Не заведён", friendly(err))
		s.back(w, r, "/employees")
		return
	}
	http.Redirect(w, r, "/employees/"+strconv.FormatInt(created.ID, 10), http.StatusSeeOther)
}

type employeeData struct {
	Employee    model.Employee
	Number      string
	NumberID    *int64
	PresetName  string
	Activations []activationRow
	Presets     []storage.PresetSummary
	FreeNumbers []storage.NumberWithHolder
	Ready       bool
	Blocker     string
}

type activationRow struct {
	model.Activation
	State model.ActivationState
}

func (s *Server) showEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	employee, err := s.DB.EmployeeByID(r.Context(), id)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	people, err := s.DB.ListEmployees(r.Context(), true)
	if err != nil {
		s.fail(w, err)
		return
	}
	var card storage.EmployeeCard
	for _, c := range people {
		if c.ID == id {
			card = c
			break
		}
	}

	activations, err := s.DB.ListActivations(r.Context(), id)
	if err != nil {
		s.fail(w, err)
		return
	}
	rows := make([]activationRow, 0, len(activations))
	now := time.Now()
	for _, a := range activations {
		rows = append(rows, activationRow{Activation: a, State: a.State(now)})
	}

	presets, err := s.DB.ListPresets(r.Context(), false)
	if err != nil {
		s.fail(w, err)
		return
	}
	numbers, err := s.DB.ListNumbers(r.Context(), false)
	if err != nil {
		s.fail(w, err)
		return
	}
	free := numbers[:0:0]
	for _, n := range numbers {
		if n.HolderID == nil || (card.NumberID != nil && *card.NumberID == n.ID) {
			free = append(free, n)
		}
	}

	// Готовность считается заранее и показывается на месте: «Выпустить ключ» с
	// отказом после нажатия — это тот же отказ, только позже и обиднее.
	data := employeeData{
		Employee: employee, Number: card.Number, NumberID: card.NumberID,
		PresetName: card.PresetName, Activations: rows,
		Presets: presets, FreeNumbers: free,
	}
	if _, err := s.DB.SubjectForIssue(r.Context(), id); err != nil {
		data.Blocker = friendly(err)
	} else if password, _ := s.DB.Setting(r.Context(), storage.SettingAdminPassword); password == "" {
		data.Blocker = "Не задан административный пароль конторы — задайте его в настройках"
	} else {
		data.Ready = true
	}

	s.render(w, r, "employee", page{
		Title: employee.Name, Section: "employees", Admin: admin, Data: data,
	})
}

func (s *Server) setEmployeePreset(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	var presetID any
	if raw := r.FormValue("preset_id"); raw != "" {
		presetID, err = strconv.ParseInt(raw, 10, 64)
		if err != nil {
			s.flash(r, "bad", "Не сохранено", "Непонятная предустановка")
			s.back(w, r, "/employees")
			return
		}
	}

	if _, err := s.DB.Exec(`UPDATE employees SET preset_id = ? WHERE id = ?`, presetID, id); err != nil {
		s.flash(r, "bad", "Не сохранено", err.Error())
	} else {
		s.flash(r, "ok", "Предустановка назначена",
			"Она поедет в следующий выпущенный ключ. Уже настроенные машины получат её из файла на R2.")
	}
	s.back(w, r, "/employees/"+strconv.FormatInt(id, 10))
}

func (s *Server) setEmployeeNumber(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	if r.FormValue("number_id") == "" {
		if err := s.DB.ReleaseNumber(r.Context(), actorOf(admin), id); err != nil {
			s.flash(r, "bad", "Не освобождён", friendly(err))
		} else {
			s.flash(r, "ok", "Номер освобождён", "")
		}
		s.back(w, r, "/employees/"+strconv.FormatInt(id, 10))
		return
	}

	numberID, err := strconv.ParseInt(r.FormValue("number_id"), 10, 64)
	if err != nil {
		s.flash(r, "bad", "Не закреплён", "Непонятный номер")
		s.back(w, r, "/employees/"+strconv.FormatInt(id, 10))
		return
	}

	if err := s.DB.AssignNumber(r.Context(), actorOf(admin), id, numberID); err != nil {
		s.flash(r, "bad", "Не закреплён", friendly(err))
	} else {
		s.flash(r, "ok", "Номер закреплён",
			"Уже выпущенные ключи несут прежний номер — если ключ ещё не использован, выпустите новый.")
	}
	s.back(w, r, "/employees/"+strconv.FormatInt(id, 10))
}

func (s *Server) dismissEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	if err := s.DB.DismissEmployee(r.Context(), actorOf(admin), id); err != nil {
		s.flash(r, "bad", "Не уволен", friendly(err))
		s.back(w, r, "/employees/"+strconv.FormatInt(id, 10))
		return
	}

	// Главное предупреждение этого действия. Панель после активации до машины
	// не дотягивается: пока пароль пира на АТС не сменят, уволенный продолжает
	// снимать звонки из очереди.
	s.flash(r, "warn", "Сотрудник уволен",
		"Номер освобождён, активации отозваны. Машина продолжит регистрироваться, пока на АТС не сменят SIP-пароль пира — сделайте это сейчас.")
	http.Redirect(w, r, "/employees", http.StatusSeeOther)
}

func (s *Server) issueKey(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	key, _, err := s.Issuer.Issue(r.Context(), actorOf(admin), id, strings.TrimSpace(r.FormValue("note")))
	if err != nil {
		s.flash(r, "bad", "Ключ не выпущен", friendly(err))
		s.back(w, r, "/employees/"+strconv.FormatInt(id, 10))
		return
	}

	s.flashKey(r, key.String(),
		"Передайте его сотруднику. Ключ действует двое суток, срабатывает один раз и больше нигде не показывается — панель его не хранит.")
	http.Redirect(w, r, "/employees/"+strconv.FormatInt(id, 10), http.StatusSeeOther)
}

func (s *Server) revokeActivation(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	if err := s.DB.RevokeActivation(r.Context(), actorOf(admin), id); err != nil {
		s.flash(r, "bad", "Не отозвано", friendly(err))
	} else {
		s.flash(r, "warn", "Активация отозвана",
			"Это учётная запись, а не отключение: машина продолжит работать, пока на АТС не сменят SIP-пароль пира.")
	}
	s.back(w, r, "/employees")
}

// ----------------------------------------------------------------- номера

func (s *Server) showNumbers(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	numbers, err := s.DB.ListNumbers(r.Context(), r.URL.Query().Get("all") == "1")
	if err != nil {
		s.fail(w, err)
		return
	}
	s.render(w, r, "numbers", page{
		Title: "Номера", Section: "numbers", Admin: admin, Data: numbers,
	})
}

func (s *Server) createNumber(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	number := strings.TrimSpace(r.FormValue("number"))
	password := r.FormValue("sip_password")
	label := strings.TrimSpace(r.FormValue("label"))

	if number == "" || password == "" {
		s.flash(r, "bad", "Не заведён", "Нужны номер и SIP-пароль — оба берутся с АТС")
		s.back(w, r, "/numbers")
		return
	}

	if _, err := s.DB.CreateNumber(r.Context(), actorOf(admin), number, password, label); err != nil {
		s.flash(r, "bad", "Не заведён", friendly(err))
	} else {
		s.flash(r, "ok", "Номер заведён", "")
	}
	s.back(w, r, "/numbers")
}

func (s *Server) setNumberPassword(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	password := r.FormValue("sip_password")
	if password == "" {
		s.flash(r, "bad", "Не сохранён", "Пустой пароль")
		s.back(w, r, "/numbers")
		return
	}

	if err := s.DB.SetNumberPassword(r.Context(), actorOf(admin), id, password); err != nil {
		s.flash(r, "bad", "Не сохранён", friendly(err))
	} else {
		s.flash(r, "warn", "Пароль записан",
			"Панель ничего не меняет на самой АТС — смените пароль пира там же. Машинам новый пароль достанется только с новым ключом.")
	}
	s.back(w, r, "/numbers")
}

func (s *Server) retireNumber(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	if err := s.DB.RetireNumber(r.Context(), actorOf(admin), id); err != nil {
		s.flash(r, "bad", "Не выведен", friendly(err))
	} else {
		s.flash(r, "ok", "Номер выведен из обращения", "")
	}
	s.back(w, r, "/numbers")
}

// ------------------------------------------------------------------ журнал

func (s *Server) showAudit(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	entries, err := s.DB.AuditPage(r.Context(), 300)
	if err != nil {
		s.fail(w, err)
		return
	}
	s.render(w, r, "audit", page{
		Title: "Журнал", Section: "audit", Admin: admin, Data: entries,
	})
}

// --------------------------------------------------------------- настройки

type settingsData struct {
	AdminPasswordSet bool
}

func (s *Server) showSettings(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	password, err := s.DB.Setting(r.Context(), storage.SettingAdminPassword)
	if err != nil {
		s.fail(w, err)
		return
	}
	s.render(w, r, "settings", page{
		Title: "Настройки", Section: "settings", Admin: admin,
		Data: settingsData{AdminPasswordSet: password != ""},
	})
}

func (s *Server) saveSettings(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	password := r.FormValue("admin_password")
	if strings.TrimSpace(password) == "" {
		s.flash(r, "bad", "Не сохранено", "Пустой пароль")
		s.back(w, r, "/settings")
		return
	}

	if err := s.DB.SetSetting(r.Context(), actorOf(admin), storage.SettingAdminPassword, password); err != nil {
		s.flash(r, "bad", "Не сохранено", friendly(err))
	} else {
		s.flash(r, "ok", "Пароль конторы сохранён",
			"Он поедет в пакеты активации. Уже настроенные машины сохранят прежний — у них он вшит с прошлого ключа.")
	}
	s.back(w, r, "/settings")
}
