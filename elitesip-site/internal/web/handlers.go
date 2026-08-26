package web

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/panel"
	"github.com/koreva/elitesip-site/internal/storage"
)

// -------------------------------------------------------------------- обзор

type overviewData struct {
	storage.Overview

	// PresetsWithoutPassword — сколько предустановок остались без
	// административного пароля. По такой ключ не выпускается вовсе.
	PresetsWithoutPassword int

	AppLinkSet bool
	HasPresets bool

	// Behind — машины, отставшие от выложенной ревизии своей предустановки.
	Behind int

	// PendingKeys — выданные ключи, которых ещё не забрали. Плитка, а не
	// строка счётчика: это одно из двух чисел, на которые смотрят не один раз.
	PendingKeys int

	// KnowsMachines — панель хоть раз что-то узнала о машинах.
	//
	// Пока Worker не заведён или ни одна машина не отметилась, плитка
	// «отставшие» не показывается вовсе: пустая плитка без объяснения читается
	// как поломка, а не как отсутствие сведений.
	KnowsMachines bool

	// ActiveSandboxes — сколько песков идёт прямо сейчас. Обзор сквозной на все
	// продукты, и у песочницы там своя строка, а не пометка «в разработке».
	ActiveSandboxes int
}

// showOverview рисует первый экран — сквозную сводку по всем продуктам.
//
// Инструкции с него убраны 25 августа 2026 до тех пор, пока не будут написаны
// заново. Возражение против отдельного экрана («на тридцати сотрудниках он
// почти всегда пуст») тем самым вернулось в силу: снимали его именно они.
// Ставка на то, что понятного интерфейса хватит; если не хватит — вернуть
// инструкции дешевле, чем строить под них раздел заранее.
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
	link, _ := s.DB.Setting(r.Context(), storage.SettingAppLink)

	withoutPassword := 0
	for _, p := range presets {
		if !p.AdminPasswordSet {
			withoutPassword++
		}
	}

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

	pending := 0
	for _, end := range overview.Loose {
		if end.Kind == "key" {
			pending++
		}
	}

	sandboxes, err := s.Sand.CountActive(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}

	s.render(w, r, "overview", page{
		Title: "Обзор", Section: "overview", Admin: admin,
		Data: overviewData{
			Overview:               overview,
			PresetsWithoutPassword: withoutPassword,
			AppLinkSet:             link != "",
			HasPresets:             len(presets) > 0,
			Behind:                 behind,
			PendingKeys:            pending,
			KnowsMachines:          len(known) > 0,
			ActiveSandboxes:        sandboxes,
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

// -------------------------------------------------------------- выдача ключа

// keysData — приветственный экран раздела «Выдать ключ».
type keysData struct {
	Presets    []storage.PresetSummary
	LastPreset *int64
	Recent     []storage.RecentIssue
}

// showKeys рисует раздел «Выдать ключ» — точку приземления EliteSIP.
//
// Открывается не формой, а объяснением и памятью о последних выдачах: нажатие
// на «EliteSIP» в ряду ведёт сюда, и подсовывать форму тому, кто шёл смотреть
// список, незачем. Сама форма разворачивается кнопкой «Приступить» — одна, как
// и была: шагов здесь не заводится.
func (s *Server) showKeys(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	presets, err := s.DB.ListPresets(r.Context(), false)
	if err != nil {
		s.fail(w, err)
		return
	}
	// Пять последних. Не хвосты — их место на обзоре; здесь память о том, кому
	// уже выдавали на этой неделе.
	recent, err := s.DB.RecentIssues(r.Context(), 5)
	if err != nil {
		s.fail(w, err)
		return
	}

	s.render(w, r, "keys", page{
		Title: "Выдать ключ", Section: "keys", Admin: admin,
		Data: keysData{Presets: presets, LastPreset: s.lastPreset(r), Recent: recent},
	})
}

// stubData — продукт, которого ещё нет.
type stubData struct {
	Name  string
	About string
	Plans []string
}

// showPBX рисует настоящую страницу, а не неактивный пункт.
//
// Пункт, который «ничего не делает», на телефоне читается как поломка: там нет
// ни наведения, ни курсора, по которым видно, что он отключён. У песочницы
// такая же заглушка стояла до 26 августа 2026 — теперь у неё свой раздел.
func (s *Server) showPBX(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	s.render(w, r, "stub", page{
		Title: "PBX", Section: "pbx", Admin: admin,
		Data: stubData{
			Name:  "PBX",
			About: "Работа с самой АТС: пиры, очереди, маршруты. Пока всё это заводится руками на сервере, и панель туда не ходит.",
			Plans: []string{
				"Завести пира и увидеть его состояние — сейчас номер и SIP-пароль вбиваются в EliteSIP руками с уже заведённого пира.",
				"Смена пароля пира при увольнении — единственное, что на самом деле останавливает машину.",
				"Очереди и то, кто в них состоит.",
			},
		},
	})
}

// ------------------------------------------------------------- сотрудники

type employeesData struct {
	Employees  []storage.EmployeeCard
	Presets    []storage.PresetSummary
	Query      string
	PresetID   *int64
	LastPreset *int64

	// Machines — состояние машин по каждому сотруднику, для пятой колонки
	// списка. Ключ — идентификатор сотрудника.
	Machines map[int64]storage.MachineState
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

	states, err := s.DB.MachineStates(r.Context(), time.Now())
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
			Machines:   states,
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
	e, ok := s.employeeFromForm(w, r, "/keys")
	if !ok {
		return
	}

	created, err := s.DB.CreateEmployee(r.Context(), actorOf(admin), e)
	if err != nil {
		s.flash(r, "bad", "Не заведён", friendly(err))
		s.back(w, r, "/keys")
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

	// Highlight — строка, которую надо подсветить: сюда пришли поиском по
	// ключу. Ноль — пришли обычным путём.
	Highlight int64
}

type activationRow struct {
	storage.MachineRow
	State model.ActivationState

	// Silent — машина молчит дольше срока. Считается здесь, а не в шаблоне:
	// шаблон не место для арифметики со временем.
	Silent bool

	// CanReflash — можно ли выпустить ключ перепрошивки. Только для живой
	// активированной машины: перепрошивать нечего там, где ключ ещё не
	// вводили, и незачем там, где активацию отозвали.
	CanReflash bool
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
		state := m.State(now)
		rows = append(rows, activationRow{
			MachineRow: m,
			State:      state,
			Silent:     m.Checkin != nil && m.Checkin.Silent(now),
			CanReflash: state == model.ActivationDone,
		})
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
		Highlight: highlightFrom(r),
	}
	if _, err := s.DB.SubjectForIssue(r.Context(), id); err != nil {
		data.Blocker = friendly(err)
	} else if employee.PresetID != nil {
		if password, _ := s.DB.PresetAdminPassword(r.Context(), *employee.PresetID); password == "" {
			data.Blocker = "У предустановки не задан административный пароль — задайте его в её карточке"
		} else {
			data.Ready = true
		}
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

	if err := s.Revoker.Revoke(r.Context(), actorOf(admin), id); err != nil {
		s.flash(r, "bad", "Не отозвано", friendly(err))
	} else {
		s.flash(r, "warn", "Активация отозвана",
			"Машина сбросится, когда следующий раз выйдет на связь — не позже чем через пятнадцать минут. "+
				"Если она в сети не появится, остановить её может только смена SIP-пароля пира на АТС.")
	}
	s.back(w, r, "/employees")
}

// ------------------------------------------------------------------ журнал

// auditData — журнал вместе с тем, чем его отбирают.
type auditData struct {
	Entries []model.AuditEntry
	Actions []string
	Actors  []string

	Action string
	Actor  string
	Period string
	Query  string

	// HasMore — есть ли что показать за этой страницей. Считается лишней
	// строкой в выборке, а не отдельным COUNT: пересчитывать весь журнал ради
	// кнопки «показать ещё» незачем.
	HasMore bool
	Shown   int
}

// auditPageSize — сколько строк за раз. Кнопка «показать ещё» добирает хвост.
const auditPageSize = 100

// showAudit рисует журнал.
//
// Доказательная подшивка, а не лента: её открывают по конкретному поводу —
// «кто сидел на 172 в прошлый вторник», «кто выложил правку, от которой
// перестал звонить телефон». Отсюда четыре отбора и месяц по умолчанию.
func (s *Server) showAudit(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	query := r.URL.Query()
	data := auditData{
		Action: query.Get("kind"),
		Actor:  query.Get("who"),
		Period: query.Get("period"),
		Query:  strings.TrimSpace(query.Get("q")),
	}
	if data.Period == "" {
		data.Period = "month"
	}

	shown := auditPageSize
	if raw := query.Get("shown"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > auditPageSize && n <= 10000 {
			shown = n
		}
	}
	data.Shown = shown

	filter := storage.AuditFilter{
		Action: data.Action,
		Actor:  data.Actor,
		Since:  auditSince(data.Period, time.Now()),
		Query:  data.Query,
		// Одна лишняя строка сверх показываемых — по ней и видно, есть ли хвост.
		Limit: shown + 1,
	}

	entries, err := s.DB.AuditPage(r.Context(), filter)
	if err != nil {
		s.fail(w, err)
		return
	}
	if len(entries) > shown {
		data.HasMore = true
		entries = entries[:shown]
	}
	data.Entries = entries

	if data.Actions, err = s.DB.AuditActions(r.Context()); err != nil {
		s.fail(w, err)
		return
	}
	if data.Actors, err = s.DB.AuditActors(r.Context()); err != nil {
		s.fail(w, err)
		return
	}

	s.render(w, r, "audit", page{
		Title: "Журнал", Section: "audit", Admin: admin, Data: data,
	})
}

// auditSince переводит выбранный срок в дату.
//
// Готовые сроки, а не два поля с датами: «прошлый вторник» ищут глазами по
// странице за неделю, а календарь на такой вопрос заставляет отвечать дважды.
func auditSince(period string, now time.Time) time.Time {
	switch period {
	case "today":
		return now.Truncate(24 * time.Hour)
	case "week":
		return now.AddDate(0, 0, -7)
	case "all":
		return time.Time{}
	default:
		return now.AddDate(0, -1, 0)
	}
}

// --------------------------------------------------------------- настройки

type settingsData struct {
	AppLink string

	// Users — пользователи панели. Заполняется только администратору.
	Users []model.Admin
}

func (s *Server) showSettings(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	link, err := s.DB.Setting(r.Context(), storage.SettingAppLink)
	if err != nil {
		s.fail(w, err)
		return
	}

	// Список пользователей читается только администратору: техподдержке он не
	// запрещён по смыслу, но и делать ей с ним нечего, а логины коллег на
	// экране — лишнее место, где их можно прочитать через плечо.
	var users []model.Admin
	if admin.IsAdmin() {
		users, err = s.DB.ListAdmins(r.Context())
		if err != nil {
			s.fail(w, err)
			return
		}
	}

	s.render(w, r, "settings", page{
		Title: "Настройки", Section: "settings", Admin: admin,
		Data: settingsData{AppLink: link, Users: users},
	})
}

// createUser заводит пользователя панели.
func (s *Server) createUser(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	login := strings.TrimSpace(r.FormValue("login"))
	password := r.FormValue("password")
	role := model.RoleSupport
	if r.FormValue("role") == string(model.RoleAdmin) {
		role = model.RoleAdmin
	}

	if login == "" {
		s.flash(r, "bad", "Не заведён", "Имя не может быть пустым")
		s.back(w, r, "/settings")
		return
	}
	if len([]rune(password)) < 8 {
		s.flash(r, "bad", "Не заведён", "Пароль не короче восьми знаков")
		s.back(w, r, "/settings")
		return
	}

	hash, err := panel.HashPassword(password)
	if err != nil {
		s.flash(r, "bad", "Не заведён", friendly(err))
		s.back(w, r, "/settings")
		return
	}
	if _, err := s.DB.CreateAdminWithRole(r.Context(), actorOf(admin), login, hash, role); err != nil {
		s.flash(r, "bad", "Не заведён", friendly(err))
		s.back(w, r, "/settings")
		return
	}

	s.flash(r, "ok", "Пользователь заведён",
		"Передайте ему имя и пароль — сменить пароль он сможет сам, в «Настройках».")
	s.back(w, r, "/settings")
}

// deleteUser гасит пользователя панели.
//
// Гасит, а не удаляет: строки журнала должны остаться читаемыми. Два края
// закрыты здесь, и оба бытовые, а не про безопасность: себя удалить нельзя —
// жмут «удалить» в списке и попадают в свою строку; последнего администратора
// удалить нельзя — панель осталась бы без того, кто заводит пользователей, и
// чинилось бы это только командной строкой.
func (s *Server) deleteUser(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if id == admin.ID {
		s.flash(r, "bad", "Не удалён", "Себя удалить нельзя")
		s.back(w, r, "/settings")
		return
	}

	target, err := s.DB.AdminByID(r.Context(), id)
	if err != nil {
		s.flash(r, "bad", "Не удалён", "Такого пользователя нет")
		s.back(w, r, "/settings")
		return
	}
	if target.IsAdmin() {
		count, err := s.DB.AdminRoleCount(r.Context(), model.RoleAdmin)
		if err != nil {
			s.fail(w, err)
			return
		}
		if count <= 1 {
			s.flash(r, "bad", "Не удалён",
				"Это последний администратор. Без него некому заводить пользователей, и вернуть его можно будет только из командной строки.")
			s.back(w, r, "/settings")
			return
		}
	}

	if err := s.DB.DisableAdmin(r.Context(), actorOf(admin), id); err != nil {
		s.flash(r, "bad", "Не удалён", friendly(err))
		s.back(w, r, "/settings")
		return
	}
	s.flash(r, "ok", "Пользователь удалён",
		"Его сеансы оборваны. В журнале он остаётся: иначе его действия стали бы безымянными.")
	s.back(w, r, "/settings")
}

// resetUserPassword задаёт чужой пароль.
//
// Нужен ровно затем, что забытый пароль техподдержки иначе не сбрасывается
// никак. Чужой логин при этом не меняется: логин — подпись в журнале.
func (s *Server) resetUserPassword(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	password := r.FormValue("password")
	if len([]rune(password)) < 8 {
		s.flash(r, "bad", "Пароль не сменён", "Не короче восьми знаков")
		s.back(w, r, "/settings")
		return
	}

	hash, err := panel.HashPassword(password)
	if err != nil {
		s.flash(r, "bad", "Пароль не сменён", friendly(err))
		s.back(w, r, "/settings")
		return
	}
	if err := s.DB.SetAdminPassword(r.Context(), actorOf(admin), id, hash); err != nil {
		s.flash(r, "bad", "Пароль не сменён", friendly(err))
		s.back(w, r, "/settings")
		return
	}
	s.flash(r, "ok", "Пароль сменён", "Его сеансы оборваны — войдёт заново с новым паролем.")
	s.back(w, r, "/settings")
}

// changeOwnPassword меняет пароль тому, кто вошёл.
//
// Пароль администратора — это доступ ко всем SIP-паролям конторы, и до
// 25 августа 2026 сменить его из панели было нельзя вовсе: только через
// командную строку, то есть позвав того, кто панель ставил.
func (s *Server) changeOwnPassword(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	current := r.FormValue("current")
	next := r.FormValue("password")

	stored, err := s.DB.AdminByLogin(r.Context(), admin.Login)
	if err != nil || panel.CheckPassword(stored.PasswordHash, current) != nil {
		// Нынешний пароль спрашивается не для порядка: панель открывают надолго
		// и оставляют открытой, и без него сменить пароль может любой, кто сел
		// за чужой стол.
		s.flash(r, "bad", "Пароль не сменён", "Нынешний пароль не подошёл")
		s.back(w, r, "/settings")
		return
	}
	if len([]rune(next)) < 8 {
		s.flash(r, "bad", "Пароль не сменён", "Не короче восьми знаков")
		s.back(w, r, "/settings")
		return
	}

	hash, err := panel.HashPassword(next)
	if err != nil {
		s.flash(r, "bad", "Пароль не сменён", friendly(err))
		s.back(w, r, "/settings")
		return
	}
	if err := s.DB.SetAdminPassword(r.Context(), actorOf(admin), admin.ID, hash); err != nil {
		s.flash(r, "bad", "Пароль не сменён", friendly(err))
		s.back(w, r, "/settings")
		return
	}
	s.flash(r, "ok", "Пароль сменён", "Прежние сеансы в других браузерах остаются открытыми.")
	s.back(w, r, "/settings")
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

// savePresetPassword задаёт административный пароль предустановки.
//
// Пароль у каждой предустановки свой: у техподдержки своя предустановка со
// своим паролем, и общий на контору сделал бы это разделение мнимым.
func (s *Server) savePresetPassword(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	password := r.FormValue("admin_password")
	if strings.TrimSpace(password) == "" {
		s.flash(r, "bad", "Не сохранено", "Пустой пароль")
		s.back(w, r, "/presets/"+strconv.FormatInt(id, 10))
		return
	}

	if err := s.DB.SetPresetAdminPassword(r.Context(), actorOf(admin), id, password); err != nil {
		s.flash(r, "bad", "Не сохранено", friendly(err))
		s.back(w, r, "/presets/"+strconv.FormatInt(id, 10))
		return
	}

	// Пароль разносится по работающим машинам сразу, а не «когда-нибудь».
	//
	// В общий файл предустановок блок доступа не входит намеренно, значит
	// доехать сам он не может ничем: панель обязана переписать помашинные
	// объекты. Раньше здесь стояло обещание, что машины получат пароль «при
	// следующей выкладке доступа», — а выкладки такой в коде не было вовсе,
	// и пароль не доезжал никогда.
	switch done, err := s.Access.Republish(r.Context(), id); {
	case err != nil:
		s.flash(r, "warn", "Пароль сохранён, но разошёлся не всем", friendly(err))
	case done == 0:
		s.flash(r, "ok", "Пароль предустановки сохранён",
			"Он поедет в ключи, которые вы выпустите. Работающих машин у этой предустановки пока нет.")
	default:
		s.flash(r, "ok", "Пароль предустановки сохранён",
			fmt.Sprintf("Он поедет в новые ключи и уже разослан работающим машинам: %d. "+
				"На них он сменится в течение двух часов — или сразу, если нажать «Проверить сейчас» в «Аккаунте».", done))
	}
	s.back(w, r, "/presets/"+strconv.FormatInt(id, 10))
}
