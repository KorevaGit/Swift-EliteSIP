package web

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/storage"
)

// -------------------------------------------------------------------- обзор

type overviewData struct {
	storage.Overview
	AdminPasswordSet bool
	AppLinkSet       bool
	HasPresets       bool

	// Behind — машины, отставшие от выложенной ревизии своей предустановки.
	Behind int

	// KnowsMachines — панель хоть раз что-то узнала о машинах.
	//
	// Пока Worker не заведён или ни одна машина не отметилась, плитка
	// «отставшие» не показывается вовсе: пустая плитка без объяснения читается
	// как поломка, а не как отсутствие сведений.
	KnowsMachines bool
}

// showOverview рисует первый экран.
//
// Я возражал против отдельного экрана: на тридцати сотрудниках он почти всегда
// пуст, и его перестали бы читать. Возражение снято инструкциями — они держат
// экран полезным и в тихий день, когда хвостов нет.
func (s *Server) showOverview(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	overview, err := s.DB.Overview(r.Context(), time.Now())
	if err != nil {
		s.fail(w, err)
		return
	}
	presets, err := s.DB.ListPresets(r.Context(), false)
	if err != nil {
		s.fail(w, err)
		return
	}
	password, _ := s.DB.Setting(r.Context(), storage.SettingAdminPassword)
	link, _ := s.DB.Setting(r.Context(), storage.SettingAppLink)

	behind, err := s.DB.BehindVersion(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	known, err := s.DB.KnownCheckins(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}

	s.render(w, r, "overview", page{
		Title: "Обзор", Section: "overview", Admin: admin,
		Data: overviewData{
			Overview:         overview,
			AdminPasswordSet: password != "",
			AppLinkSet:       link != "",
			HasPresets:       len(presets) > 0,
			Behind:           behind,
			KnowsMachines:    len(known) > 0,
		},
	})
}

// pullMarks заходит за отметками Worker'а по нажатию.
//
// Кнопка есть, хотя панель ходит и сама раз в пять минут: техподдержка стоит
// над сотрудником, который вводит ключ прямо сейчас, и ждать пять минут ради
// ответа «дошло» — это пять минут разговора ни о чём.
func (s *Server) pullMarks(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	result, err := s.Marks.Collect(r.Context())
	if err != nil {
		s.flash(r, "bad", "Не удалось сходить за отметками", err.Error())
		s.back(w, r, "/overview")
		return
	}

	text := fmt.Sprintf("Забранных пакетов: %d. Отметилось машин: %d.", result.Fetched, result.Checkins)
	if result.Unknown > 0 {
		// Не беда, но и не молчание: это машины удалённых сотрудников, и если
		// их вдруг стало много — на АТС давно не меняли пароли пиров.
		text += fmt.Sprintf(" Машин, которых нет в базе: %d — это машины удалённых сотрудников.", result.Unknown)
	}
	s.flash(r, "ok", "Отметки разобраны", text)
	s.back(w, r, "/overview")
}

// ------------------------------------------------------------- сотрудники

type employeesData struct {
	Employees  []storage.EmployeeCard
	Presets    []storage.PresetSummary
	Query      string
	PresetID   *int64
	LastPreset *int64
}

func (s *Server) showEmployees(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	filter := storage.EmployeeFilter{Query: strings.TrimSpace(r.URL.Query().Get("q"))}
	if raw := r.URL.Query().Get("preset"); raw != "" {
		if id, err := strconv.ParseInt(raw, 10, 64); err == nil {
			filter.PresetID = &id
		}
	}

	people, err := s.DB.ListEmployees(r.Context(), filter)
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
		Data: employeesData{
			Employees: people, Presets: presets,
			Query: filter.Query, PresetID: filter.PresetID,
			LastPreset: s.lastPreset(r),
		},
	})
}

// lastPreset — предустановка, выбранная в прошлый раз.
//
// Подставляется в форму заведения: стажёры приходят пачками, и все по одной
// предустановке. Отсутствующая или архивная не мешает — шаблон просто не
// найдёт её в списке и оставит выбор пустым.
func (s *Server) lastPreset(r *http.Request) *int64 {
	raw, err := s.DB.Setting(r.Context(), storage.SettingLastPreset)
	if err != nil || raw == "" {
		return nil
	}
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return nil
	}
	return &id
}

// createEmployee заводит сотрудника и сразу выпускает ему ключ.
//
// Одним действием, потому что это и есть главный путь панели: стажёры приходят
// каждую неделю, и заводят их ровно затем, чтобы выдать ключ. Раздельные
// «завести» и «выпустить» — это лишнее нажатие каждую неделю и один забытый
// ключ на десяток заведений.
//
// Если ключ выпустить не из чего — нет номера, нет ревизии предустановки, не
// задан пароль конторы, — сотрудник всё равно остаётся заведённым, а карточка
// говорит, чего не хватает. Откатывать заведение было бы хуже: человек вбил
// имя, номер и пароль, и терять их из-за незаполненной настройки не за что.
func (s *Server) createEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	e, ok := s.employeeFromForm(w, r, "/employees")
	if !ok {
		return
	}

	created, err := s.DB.CreateEmployee(r.Context(), actorOf(admin), e)
	if err != nil {
		s.flash(r, "bad", "Не заведён", friendly(err))
		s.back(w, r, "/employees")
		return
	}
	s.rememberPreset(r, admin, e.PresetID)

	card := "/employees/" + strconv.FormatInt(created.ID, 10)
	if !s.issue(r, admin, created.ID, "") {
		s.flash(r, "warn", "Сотрудник заведён, но ключ не выпущен",
			"Карточка ниже говорит, чего не хватает. Как только это поправите — «Выпустить ключ» на месте.")
	}
	http.Redirect(w, r, card, http.StatusSeeOther)
}

// issue выпускает ключ и кладёт его в сообщение. Отказ не показывает сам:
// звать его умеют оба места, а слова у них разные.
func (s *Server) issue(r *http.Request, admin model.Admin, employeeID int64, note string) bool {
	key, saved, err := s.Issuer.Issue(r.Context(), actorOf(admin), employeeID, note)
	if err != nil {
		return false
	}

	name := ""
	if employee, err := s.DB.EmployeeByID(r.Context(), employeeID); err == nil {
		name = employee.Name
	}
	link, _ := s.DB.Setting(r.Context(), storage.SettingAppLink)

	s.flashKey(r, key.String(),
		employeeMessage(name, key.String(), saved.ExpiresAt, link),
		"Передайте его сотруднику. Ключ действует двое суток, срабатывает один раз и больше нигде не показывается — панель его не хранит.")
	return true
}

// employeeFromForm разбирает карточку из формы и сам сообщает об отказе.
//
// Номер и пароль пустыми допускаются: человека заводят и до того, как на АТС
// подняли пир. Ключ такому не выпустится, и карточка скажет об этом до нажатия.
func (s *Server) employeeFromForm(w http.ResponseWriter, r *http.Request, back string) (model.Employee, bool) {
	e := model.Employee{
		Name:        strings.TrimSpace(r.FormValue("name")),
		Number:      strings.TrimSpace(r.FormValue("number")),
		SIPPassword: strings.TrimSpace(r.FormValue("sip_password")),
	}
	if e.Name == "" {
		s.flash(r, "bad", "Не сохранено", "Имя сотрудника не может быть пустым")
		s.back(w, r, back)
		return model.Employee{}, false
	}
	if raw := r.FormValue("preset_id"); raw != "" {
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			s.flash(r, "bad", "Не сохранено", "Непонятная предустановка")
			s.back(w, r, back)
			return model.Employee{}, false
		}
		e.PresetID = &id
	}
	return e, true
}

func (s *Server) rememberPreset(r *http.Request, admin model.Admin, presetID *int64) {
	if presetID == nil {
		return
	}
	// Отказ проглатывается намеренно: подстановка в форму — удобство, и ронять
	// из-за неё заведение сотрудника не за что.
	_ = s.DB.SetSetting(r.Context(), actorOf(admin),
		storage.SettingLastPreset, strconv.FormatInt(*presetID, 10))
}

type employeeData struct {
	Employee    model.Employee
	PresetName  string
	Activations []activationRow
	Presets     []storage.PresetSummary
	Ready       bool
	Blocker     string
}

type activationRow struct {
	storage.MachineRow
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

	machines, err := s.DB.Machines(r.Context(), id)
	if err != nil {
		s.fail(w, err)
		return
	}
	rows := make([]activationRow, 0, len(machines))
	now := time.Now()
	for _, m := range machines {
		rows = append(rows, activationRow{MachineRow: m, State: m.State(now)})
	}

	presets, err := s.DB.ListPresets(r.Context(), false)
	if err != nil {
		s.fail(w, err)
		return
	}
	var presetName string
	for _, p := range presets {
		if employee.PresetID != nil && p.ID == *employee.PresetID {
			presetName = p.Name
			break
		}
	}

	// Готовность считается заранее и показывается на месте: «Выпустить ключ» с
	// отказом после нажатия — это тот же отказ, только позже и обиднее.
	data := employeeData{
		Employee: employee, PresetName: presetName,
		Activations: rows, Presets: presets,
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

func (s *Server) saveEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	back := "/employees/" + strconv.FormatInt(id, 10)

	e, ok := s.employeeFromForm(w, r, back)
	if !ok {
		return
	}
	e.ID = id

	if err := s.DB.UpdateEmployee(r.Context(), actorOf(admin), e); err != nil {
		s.flash(r, "bad", "Не сохранено", friendly(err))
	} else {
		s.flash(r, "ok", "Карточка сохранена",
			"Уже выпущенные ключи несут прежние значения — если ключ ещё не использован, выпустите новый. "+
				"Предустановка на настроенных машинах поменяется сама из файла на R2.")
	}
	s.back(w, r, back)
}

func (s *Server) deleteEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	if err := s.DB.DeleteEmployee(r.Context(), actorOf(admin), id); err != nil {
		s.flash(r, "bad", "Не удалён", friendly(err))
		s.back(w, r, "/employees/"+strconv.FormatInt(id, 10))
		return
	}

	// Главное предупреждение этого действия. Панель после активации до машины
	// не дотягивается: пока пароль пира на АТС не сменят, ушедший продолжает
	// снимать звонки из очереди.
	s.flash(r, "warn", "Сотрудник удалён",
		"Карточка, активации и отметки о связи стёрты; в журнале остались имя и номер. "+
			"Машина продолжит регистрироваться, пока на АТС не сменят SIP-пароль пира — сделайте это сейчас.")
	http.Redirect(w, r, "/employees", http.StatusSeeOther)
}

func (s *Server) issueKey(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	card := "/employees/" + strconv.FormatInt(id, 10)

	if !s.issue(r, admin, id, strings.TrimSpace(r.FormValue("note"))) {
		// Причину читаем отдельным запросом: та же проверка, что рисует
		// карточку, и слова у них поэтому одни.
		reason := "не из чего собрать пакет"
		if _, err := s.DB.SubjectForIssue(r.Context(), id); err != nil {
			reason = friendly(err)
		}
		s.flash(r, "bad", "Ключ не выпущен", reason)
	}
	http.Redirect(w, r, card, http.StatusSeeOther)
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
	AppLink          string
}

func (s *Server) showSettings(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	password, err := s.DB.Setting(r.Context(), storage.SettingAdminPassword)
	if err != nil {
		s.fail(w, err)
		return
	}
	link, err := s.DB.Setting(r.Context(), storage.SettingAppLink)
	if err != nil {
		s.fail(w, err)
		return
	}
	s.render(w, r, "settings", page{
		Title: "Настройки", Section: "settings", Admin: admin,
		Data: settingsData{AdminPasswordSet: password != "", AppLink: link},
	})
}

func (s *Server) saveAppLink(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	link := strings.TrimSpace(r.FormValue("app_link"))

	if err := s.DB.SetSetting(r.Context(), actorOf(admin), storage.SettingAppLink, link); err != nil {
		s.flash(r, "bad", "Не сохранено", friendly(err))
	} else if link == "" {
		s.flash(r, "warn", "Адрес убран",
			"В сообщении сотруднику останется «Установите EliteSIP» без ссылки — откуда качать, придётся говорить отдельно.")
	} else {
		s.flash(r, "ok", "Адрес сохранён", "Он поедет в сообщения, которые вы копируете при выдаче ключа.")
	}
	s.back(w, r, "/settings")
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
