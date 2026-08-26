package web

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/sand"
)

// maxDealsUpload — предел на файл холодной базы.
//
// Сто тысяч сделок по десятку байт — около мегабайта; восемь даны с запасом на
// лишние столбцы выгрузки. Предел нужен не от злоумышленника, а от «положил не
// тот файл»: без него панель молча приняла бы гигабайтный архив в память.
const maxDealsUpload = 8 << 20

type sandboxesData struct {
	Sandboxes []sand.SandboxCard
	Archive   bool
}

func sandEmployeeIDs(r *http.Request) (int64, int64, error) {
	sid, err := pathID(r)
	if err != nil {
		return 0, 0, err
	}
	eid, err := strconv.ParseInt(r.PathValue("eid"), 10, 64)
	if err != nil || eid <= 0 {
		return 0, 0, errors.New("bad employee id")
	}
	return sid, eid, nil
}

func (s *Server) showSandEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	sid, eid, e := sandEmployeeIDs(r)
	if e != nil {
		http.NotFound(w, r)
		return
	}
	d, e := s.Sand.GetEmployee(r.Context(), sid, eid)
	if errors.Is(e, sand.ErrEmployeeNotFound) {
		http.NotFound(w, r)
		return
	}
	if e != nil {
		s.fail(w, e)
		return
	}
	s.render(w, r, "sandbox_employee", page{Title: d.Name + " · Песочница", Section: "sandbox", Sub: "list", Admin: admin, Data: d})
}

func (s *Server) sandEmployeeBack(w http.ResponseWriter, r *http.Request, sid, eid int64) {
	s.back(w, r, fmt.Sprintf("/sandbox/%d/employee/%d", sid, eid))
}

func (s *Server) markSandEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	sid, eid, e := sandEmployeeIDs(r)
	if e != nil {
		http.NotFound(w, r)
		return
	}
	cascade := r.FormValue("cascade") == "1"
	marked, e := s.Sand.ToggleEmployeeMark(r.Context(), actorOfAdmin(admin), sid, eid, strings.TrimSpace(r.FormValue("task")), cascade)
	if e != nil {
		var c sand.CascadeRequired
		if errors.As(e, &c) {
			s.flash(r, "bad", "Нужно подтверждение", fmt.Sprintf("С этой отметкой снимется ещё %d. Повторите действие с подтверждением.", c.Count))
		} else {
			s.sandboxActionError(r, e)
		}
	} else if marked {
		s.flash(r, "ok", "Работа выполнена", "Исполнитель и время сохранены.")
	} else {
		s.flash(r, "ok", "Отметка снята", "Зависящие отметки также сняты.")
	}
	s.Sand.DeliverAudit(r.Context(), s.DB, 0)
	s.sandEmployeeBack(w, r, sid, eid)
}

func (s *Server) saveSandEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	sid, eid, e := sandEmployeeIDs(r)
	if e != nil {
		http.NotFound(w, r)
		return
	}
	e = s.Sand.SaveEmployeeBitrix(r.Context(), actorOfAdmin(admin), sid, eid, r.FormValue("login"), r.FormValue("password"), r.FormValue("bitrix_id"), r.FormValue("cascade") == "1")
	if e != nil {
		s.sandboxActionError(r, e)
	} else {
		s.flash(r, "ok", "Данные Битрикса сохранены", "Задача закроется, когда заполнены логин, пароль и ID.")
	}
	s.Sand.DeliverAudit(r.Context(), s.DB, 0)
	s.sandEmployeeBack(w, r, sid, eid)
}

func (s *Server) assignSandExtension(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	sid, eid, e := sandEmployeeIDs(r)
	if e == nil {
		e = s.Sand.AssignEmployeeExtension(r.Context(), actorOfAdmin(admin), sid, eid, r.FormValue("number"))
	}
	if e != nil {
		s.sandboxActionError(r, e)
	} else {
		s.flash(r, "ok", "Номер привязан", r.FormValue("number"))
	}
	s.Sand.DeliverAudit(r.Context(), s.DB, 0)
	s.sandEmployeeBack(w, r, sid, eid)
}

func (s *Server) outcomeSandEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	sid, eid, e := sandEmployeeIDs(r)
	if e == nil {
		e = s.Sand.SetEmployeeOutcome(r.Context(), actorOfAdmin(admin), sid, eid, sand.Outcome(r.FormValue("outcome")))
	}
	if e != nil {
		s.sandboxActionError(r, e)
	} else {
		s.flash(r, "ok", "Исход сохранён", "Для не вышедшего номер освобождён вместе с комплексным увольнением.")
	}
	s.Sand.DeliverAudit(r.Context(), s.DB, 0)
	s.sandEmployeeBack(w, r, sid, eid)
}

func (s *Server) downloadSandDeals(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	sid, eid, e := sandEmployeeIDs(r)
	n, _ := strconv.Atoi(r.URL.Query().Get("n"))
	var b sand.DealBatch
	if e == nil {
		b, e = s.Sand.IssueDeals(r.Context(), actorOfAdmin(admin), sid, eid, n)
	}
	if e != nil {
		s.sandboxActionError(r, e)
		s.sandEmployeeBack(w, r, sid, eid)
		return
	}
	d, e := s.Sand.GetEmployee(r.Context(), sid, eid)
	if e != nil {
		s.fail(w, e)
		return
	}
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="deals-%d.csv"`, b.ID))
	fmt.Fprintln(w, "1, 2")
	for _, deal := range b.Deals {
		fmt.Fprintf(w, "%s, %s\n", deal, d.BitrixID)
	}
}

func (s *Server) importedSandDeals(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	sid, eid, e := sandEmployeeIDs(r)
	bid, pe := strconv.ParseInt(r.PathValue("bid"), 10, 64)
	if e == nil {
		e = pe
	}
	if e == nil {
		e = s.Sand.MarkBatchImported(r.Context(), actorOfAdmin(admin), sid, eid, bid)
	}
	if e != nil {
		s.sandboxActionError(r, e)
	} else {
		s.flash(r, "ok", "Файл отмечен налитым", "Теперь можно получить следующую порцию.")
	}
	s.Sand.DeliverAudit(r.Context(), s.DB, 0)
	s.sandEmployeeBack(w, r, sid, eid)
}

func (s *Server) deleteSandEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	sid, eid, e := sandEmployeeIDs(r)
	if e == nil {
		e = s.Sand.DeleteEmployee(r.Context(), actorOfAdmin(admin), sid, eid)
	}
	if e != nil {
		s.sandboxActionError(r, e)
		s.sandEmployeeBack(w, r, sid, eid)
		return
	}
	s.Sand.DeliverAudit(r.Context(), s.DB, 0)
	s.flash(r, "ok", "Сотрудник удалён", "Аккаунт ещё не создавался.")
	http.Redirect(w, r, fmt.Sprintf("/sandbox/%d", sid), http.StatusSeeOther)
}

func (s *Server) showSandboxes(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	s.listSandboxes(w, r, admin, false)
}

func (s *Server) showSandboxArchive(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	s.listSandboxes(w, r, admin, true)
}

func (s *Server) listSandboxes(w http.ResponseWriter, r *http.Request, admin model.Admin, archive bool) {
	cards, err := s.Sand.ListSandboxes(r.Context(), archive)
	if err != nil {
		s.fail(w, err)
		return
	}

	title, view, sub := "Пески", "sandbox", "list"
	if archive {
		title, view, sub = "Архив песков", "sandbox_archive", "archive"
	}
	s.render(w, r, view, page{
		Title: title, Section: "sandbox", Sub: sub, Admin: admin,
		Data: sandboxesData{Sandboxes: cards, Archive: archive},
	})
}

// newSandboxData — форма создания вместе с тем, что в ней уже набрано.
//
// Набранное возвращается на экран при отказе: в форме до тридцати ФИО, и
// потерять их из-за занятого номера — это переписать всё заново.
type newSandboxData struct {
	ROPs       []string
	ROP        string
	Format     string
	Employees  string
	Extensions string
	Problem    string
}

func (s *Server) newSandbox(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	s.renderNewSandbox(w, r, admin, newSandboxData{Format: string(sand.Office)})
}

func (s *Server) renderNewSandbox(w http.ResponseWriter, r *http.Request, admin model.Admin, data newSandboxData) {
	data.ROPs = sand.ROPs()
	s.render(w, r, "sandbox_new", page{
		Title: "Новый песок", Section: "sandbox", Sub: "new", Admin: admin, Data: data,
	})
}

// createSandbox заводит песок целиком: РОП, формат, люди, пул номеров и
// холодная база одним действием.
//
// Черновиков нет: заведённый наполовину песок пришлось бы дозаполнять по
// памяти, а пустой — объяснять тому, кто найдёт его в списке.
func (s *Server) createSandbox(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	entered := newSandboxData{
		ROP:        strings.TrimSpace(r.FormValue("rop")),
		Format:     r.FormValue("format"),
		Employees:  r.FormValue("employees"),
		Extensions: strings.TrimSpace(r.FormValue("extensions")),
	}

	extensions, err := sand.ParseExtensions(entered.Extensions)
	if err != nil {
		entered.Problem = err.Error()
		s.renderNewSandbox(w, r, admin, entered)
		return
	}

	deals, err := s.uploadedDeals(r)
	if err != nil {
		entered.Problem = err.Error()
		s.renderNewSandbox(w, r, admin, entered)
		return
	}

	created, err := s.Sand.CreateSandbox(r.Context(), actorOfAdmin(admin), sand.NewSandbox{
		ROP:        entered.ROP,
		Format:     sand.Format(entered.Format),
		Employees:  lines(entered.Employees),
		Extensions: extensions,
		Deals:      deals,
	})
	if err != nil {
		if !refusedInWords(err) {
			s.fail(w, err)
			return
		}
		entered.Problem = err.Error()
		s.renderNewSandbox(w, r, admin, entered)
		return
	}

	// Событие журнала ушло в outbox одной транзакцией с песком; относим его в
	// общий журнал сразу, чтобы запись появилась на /audit к тому моменту, как
	// туда посмотрят, а не через полминуты.
	if _, err := s.Sand.DeliverAudit(r.Context(), s.DB, 0); err != nil {
		// Не беда: доставщик повторит через полминуты, а песок уже заведён.
		// Ронять из-за этого действие человека было бы неверно.
		s.flash(r, "warn", "Запись в журнал задержалась",
			"Песок заведён, но событие ещё не доехало до общего журнала. Оно доедет само.")
	}

	s.flash(r, "ok", "Песок заведён",
		describeCreated(created, len(extensions), len(deals)))
	http.Redirect(w, r, "/sandbox", http.StatusSeeOther)
}

// uploadedDeals читает пул сделок из приложенного файла.
//
// Файл необязателен: базу наливают не в первый же день, и требовать выгрузку
// в момент заведения песка значило бы держать группу без карточек, пока её
// готовят.
func (s *Server) uploadedDeals(r *http.Request) ([]string, error) {
	file, header, err := r.FormFile("deals")
	// Браузер шлёт multipart из-за поля файла. Тестовые и простые клиенты могут
	// прислать обычную urlencoded-форму — файла в ней по определению нет.
	if errors.Is(err, http.ErrMissingFile) || errors.Is(err, http.ErrNotMultipart) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("прочитать файл сделок: %w", err)
	}
	defer file.Close()

	if header != nil && header.Size == 0 {
		return nil, nil
	}
	return sand.ParseDeals(file)
}

// refusedInWords — отказ ли это, о котором форме есть что сказать человеку.
//
// Всё остальное — наша поломка, и показывать её текстом в форме нельзя: он
// ничего не объясняет тому, кто заводит песок.
func refusedInWords(err error) bool {
	for _, known := range []error{
		sand.ErrNoEmployees, sand.ErrUnknownROP, sand.ErrBadFormat,
		sand.ErrROPBusy, sand.ErrNumberBusy,
	} {
		if errors.Is(err, known) {
			return true
		}
	}
	return false
}

type sandboxTemplateData struct {
	Format   sand.Format
	Remote   bool
	Sandbox  []sand.Task
	Employee []sand.Task
	ROPs     []string
}

// showSandboxTemplate — шаблон работ, только просмотр.
//
// Правка шаблона — правка кода: редактора здесь нет и не будет. Экран нужен
// затем, чтобы на «а что вообще входит в песок» отвечала панель, а не память
// того, кто дольше работает.
func (s *Server) showSandboxTemplate(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	format := sand.Office
	if r.URL.Query().Get("format") == string(sand.Remote) {
		format = sand.Remote
	}

	s.render(w, r, "sandbox_template", page{
		Title: "Шаблон работ", Section: "sandbox", Sub: "template", Admin: admin,
		Data: sandboxTemplateData{
			Format:   format,
			Remote:   format == sand.Remote,
			Sandbox:  sand.SandboxTasks(format),
			Employee: sand.EmployeeTasks(format),
			ROPs:     sand.ROPs(),
		},
	})
}

// limitUpload ограничивает тело запроса и разбирает форму до всех проверок.
//
// Разбор здесь, а не в обработчике, нарочно: проверка токена формы читает поля
// первой, и слишком большой файл без этого выглядел бы как «форма устарела» —
// сообщение, по которому чинить нечего.
func (s *Server) limitUpload(limit int64, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, limit)
		// Форму без файла (а такая приходит, если браузер не приложил ничего)
		// пропускаем дальше: её разберёт обычная проверка токена. Отказывать
		// здесь значило бы требовать выгрузку сделок в момент заведения песка.
		if err := r.ParseMultipartForm(limit); err != nil && !errors.Is(err, http.ErrNotMultipart) {
			http.Error(w,
				"файл слишком велик или форма испорчена — проверьте, что приложена выгрузка сделок",
				http.StatusRequestEntityTooLarge)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// actorOfAdmin — кто делает действие в песочнице.
//
// Логин едет снимком: администраторы живут в другой базе, и запись в истории
// не должна зависеть от того, что станет с учётной записью потом.
func actorOfAdmin(admin model.Admin) sand.Actor {
	return sand.Actor{ID: admin.ID, Login: admin.Login}
}

// lines разбирает список ФИО — по человеку на строку.
//
// По строке, а не через запятую: в «Иванов, Иван Петрович» запятая часть имени,
// и разделив по ней, панель завела бы двух человек из одного.
func lines(raw string) []string {
	var out []string
	for _, line := range strings.Split(raw, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			out = append(out, line)
		}
	}
	return out
}

func describeCreated(created sand.Sandbox, numbers, deals int) string {
	where := "офисный"
	if created.Remote() {
		where = "удалённый"
	}

	said := "РОП " + created.ROP + ", " + where + "."
	switch {
	case numbers == 0 && deals == 0:
		return said + " Пул номеров и холодная база пока пусты — их дозаполняют по ходу."
	case numbers == 0:
		return said + " Пул номеров пока пуст."
	case deals == 0:
		return said + " Холодную базу можно налить позже."
	}
	return said
}

func (s *Server) showSandboxDetail(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	detail, err := s.Sand.GetSandbox(r.Context(), id)
	if errors.Is(err, sand.ErrNotFound) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		s.fail(w, err)
		return
	}
	s.render(w, r, "sandbox_detail", page{
		Title: "Песок · " + detail.ROP, Section: "sandbox", Sub: "list",
		Admin: admin, Data: detail,
	})
}

func (s *Server) markSandboxTask(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	marked, err := s.Sand.ToggleSandboxMark(r.Context(), actorOfAdmin(admin), id,
		strings.TrimSpace(r.FormValue("task")))
	if err != nil {
		s.sandboxActionError(r, err)
		s.back(w, r, fmt.Sprintf("/sandbox/%d", id))
		return
	}
	if _, err := s.Sand.DeliverAudit(r.Context(), s.DB, 0); err != nil {
		s.flash(r, "warn", "Журнал догонит", "Отметка сохранена; событие доедет в общий журнал само.")
	} else if marked {
		s.flash(r, "ok", "Работа выполнена", "Рядом с отметкой сохранены исполнитель и время.")
	} else {
		s.flash(r, "ok", "Отметка снята", "Предыдущее выполнение осталось в общем журнале.")
	}
	s.back(w, r, fmt.Sprintf("/sandbox/%d", id))
}

func (s *Server) addSandboxEmployee(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	name := strings.TrimSpace(r.FormValue("name"))
	if _, err := s.Sand.AddSandboxEmployee(r.Context(), actorOfAdmin(admin), id, name); err != nil {
		s.sandboxActionError(r, err)
		s.back(w, r, fmt.Sprintf("/sandbox/%d", id))
		return
	}
	s.Sand.DeliverAudit(r.Context(), s.DB, 0)
	s.flash(r, "ok", "Сотрудник добавлен", name)
	s.back(w, r, fmt.Sprintf("/sandbox/%d", id))
}

func (s *Server) addSandboxComment(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if err := s.Sand.AddSandboxComment(r.Context(), actorOfAdmin(admin), id, r.FormValue("text")); err != nil {
		s.sandboxActionError(r, err)
	} else {
		s.flash(r, "ok", "Комментарий добавлен", "Он останется в общем обсуждении песка.")
	}
	s.back(w, r, fmt.Sprintf("/sandbox/%d", id))
}

func (s *Server) closeSandbox(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if err := s.Sand.CloseSandbox(r.Context(), actorOfAdmin(admin), id); err != nil {
		s.sandboxActionError(r, err)
		s.back(w, r, fmt.Sprintf("/sandbox/%d", id))
		return
	}
	s.Sand.DeliverAudit(r.Context(), s.DB, 0)
	s.flash(r, "ok", "Песок закрыт", "Карточка перенесена в архив, её номера освобождены.")
	http.Redirect(w, r, "/sandbox/archive", http.StatusSeeOther)
}

func (s *Server) sandboxActionError(r *http.Request, err error) {
	switch {
	case errors.Is(err, sand.ErrClosed):
		s.flash(r, "bad", "Песок уже закрыт", "Архивная карточка доступна только для чтения.")
	case errors.Is(err, sand.ErrNoEmployees):
		s.flash(r, "bad", "Нужно ФИО", "Введите хотя бы фамилию и имя.")
	case errors.Is(err, sand.ErrEmptyComment):
		s.flash(r, "bad", "Комментарий пуст", "Напишите текст перед добавлением.")
	case errors.Is(err, sand.ErrTaskBlocked):
		s.flash(r, "bad", "Работа пока недоступна", "Сначала выполните указанную перед ней работу.")
	case errors.Is(err, sand.ErrTaskRequired):
		s.flash(r, "bad", "Отметку пока нельзя снять", "Сначала снимите зависящую от неё работу.")
	case errors.Is(err, sand.ErrUnknownTask), errors.Is(err, sand.ErrNotFound):
		s.flash(r, "bad", "Карточка изменилась", "Обновите страницу и попробуйте снова.")
	default:
		s.flash(r, "bad", "Действие не выполнено", err.Error())
	}
}
