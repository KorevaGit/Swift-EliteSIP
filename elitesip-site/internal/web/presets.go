package web

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/preset"
	"github.com/koreva/elitesip-site/internal/storage"
)

type presetsData struct {
	Presets []storage.PresetSummary
	Pending int
}

func (s *Server) showPresets(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	presets, err := s.DB.ListPresets(r.Context(), false)
	if err != nil {
		s.fail(w, err)
		return
	}

	pending := 0
	for _, p := range presets {
		if p.Revision > 0 && !p.Published {
			pending++
		}
	}

	s.render(w, r, "presets", page{
		Title: "Предустановки", Section: "presets", Admin: admin,
		Data: presetsData{Presets: presets, Pending: pending},
	})
}

func (s *Server) createPreset(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	name := strings.TrimSpace(r.FormValue("name"))
	if name == "" {
		s.flash(r, "bad", "Не заведена", "Название не может быть пустым")
		s.back(w, r, "/presets")
		return
	}

	created, err := s.DB.CreatePreset(r.Context(), actorOf(admin), name)
	if err != nil {
		s.flash(r, "bad", "Не заведена", friendly(err))
		s.back(w, r, "/presets")
		return
	}
	http.Redirect(w, r, "/presets/"+strconv.FormatInt(created.ID, 10), http.StatusSeeOther)
}

type presetData struct {
	Preset   model.Preset
	Revision model.PresetRevision
	HasSaved bool
	Fields   preset.Fields
	Problems []string

	// AdminPasswordSet — задан ли административный пароль этой предустановки.
	AdminPasswordSet bool

	// AdminPassword — он сам, открытым текстом.
	//
	// Показывается с 25 августа 2026 и именно техподдержке: это её пароль от
	// «Управления» на машине сотрудника, и без него она не может ни настроить
	// рабочее место, ни разобрать жалобу. Прежде он не показывался вовсе —
	// то есть задавший его администратор был единственным, кто его знал.
	//
	// Цена та же, что у открытого SIP-пароля: снимок этого экрана — доступ.
	AdminPassword string

	Revisions []storage.RevisionRow

	// Pending — что уедет на машины при следующей выкладке, словами и
	// разделённое по цене ошибки.
	//
	// Считается от последней выложенной ревизии, а не от предыдущей
	// сохранённой: сравнивать надо с тем, что сейчас стоит на машинах.
	Pending      preset.Report
	Trouble      string
	NeedsPublish bool

	// Employees и Machines — кого касается выкладка.
	Employees int
	Machines  int

	// Others — прочие предустановки, из которых можно взять раздел.
	Others []storage.PresetSummary

	// DangerousRollback — ревизии, откат на которые трогает опасные поля.
	// Ключ — идентификатор ревизии. Откат остаётся мгновенным; подтверждение
	// спрашивается только у этих.
	DangerousRollback map[int64]bool

	// FirstPublish — выкладок ещё не было, сравнивать не с чем.
	FirstPublish bool
}

// showPreset рисует предустановку на просмотр, editPreset — её же на правку.
//
// Разделены 25 августа 2026 вместо свёрнутых разделов и замка: гармошка была
// ответом на «форму открывают раз в квартал и боятся тронуть лишнее», а
// разделение отвечает на то же самое честнее — случайно не тронешь то, что
// вообще не поле ввода.
func (s *Server) showPreset(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	s.renderPreset(w, r, admin, "preset")
}

func (s *Server) editPreset(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	s.renderPreset(w, r, admin, "preset_edit")
}

// borrowSection подставляет в форму правки один раздел из другой предустановки.
//
// Адреса АТС и стук у всех предустановок конторы одинаковые, очереди повторяются,
// а раскладку клавиш новому отделу проще взять у соседнего и поправить, чем
// набрать заново. Копирования предустановки целиком нет намеренно: нужен как
// раз стук от «Менеджера» при своём адресе удалёнщика.
//
// Ничего не сохраняется. Форма приходит целиком, раздел в ней подменяется, и
// страница рисуется заново — то, что человек уже успел напечатать в других
// разделах, остаётся на месте, а ревизию создаёт только «Сохранить».
func (s *Server) borrowSection(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	card := "/presets/" + strconv.FormatInt(id, 10)

	if err := r.ParseForm(); err != nil {
		s.flash(r, "bad", "Не взято", "Форма не разобралась")
		s.back(w, r, card+"/edit")
		return
	}

	// Раздел приходит значением самой кнопки, источник — списком рядом с ней:
	// так у каждого раздела свой выбор, и нажатие не может подставить не туда.
	section := r.FormValue("section")
	sourceID, err := strconv.ParseInt(r.FormValue("from_"+section), 10, 64)
	if err != nil {
		s.flash(r, "bad", "Не взято", "Не выбрано, откуда брать")
		s.back(w, r, card+"/edit")
		return
	}

	sourceRevision, err := s.DB.LatestRevision(r.Context(), sourceID)
	if err != nil {
		s.flash(r, "bad", "Не взято", "У выбранной предустановки нет ни одной сохранённой ревизии")
		s.back(w, r, card+"/edit")
		return
	}
	parsed, err := preset.Parse(sourceRevision.Payload)
	if err != nil {
		s.flash(r, "bad", "Не взято", "Ревизия источника не читается: "+err.Error())
		s.back(w, r, card+"/edit")
		return
	}
	source := fillGaps(parsed)

	// Напечатанное в форме важнее сохранённого: человек уже что-то правил.
	current, err := fieldsFromForm(r)
	if err != nil {
		s.flash(r, "bad", "Не взято", err.Error())
		s.back(w, r, card+"/edit")
		return
	}
	current = fillGaps(current)

	switch section {
	case "dtmf":
		current.DTMF, current.Conference = source.DTMF, source.Conference
	case "queues":
		current.Queues = source.Queues
	case "guard":
		current.IncomingCall = source.IncomingCall
	case "link":
		current.SiteAddress, current.PortKnock = source.SiteAddress, source.PortKnock
		current.AcceptsAnyTLSCertificate = source.AcceptsAnyTLSCertificate
	default:
		s.flash(r, "bad", "Не взято", "Непонятный раздел")
		s.back(w, r, card+"/edit")
		return
	}

	s.flash(r, "warn", "Раздел подставлен в форму",
		"Ничего ещё не сохранено: посмотрите, что получилось, и нажмите «Сохранить ревизию».")
	s.renderPresetWith(w, r, admin, "preset_edit", id, &current)
}

func (s *Server) renderPreset(w http.ResponseWriter, r *http.Request, admin model.Admin, view string) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	s.renderPresetWith(w, r, admin, view, id, nil)
}

// renderPresetWith рисует предустановку; override — поля, которые надо
// показать вместо сохранённых (форма после подстановки раздела).
func (s *Server) renderPresetWith(w http.ResponseWriter, r *http.Request, admin model.Admin, view string, id int64, override *preset.Fields) {
	list, err := s.DB.ListPresets(r.Context(), true)
	if err != nil {
		s.fail(w, err)
		return
	}
	var found *storage.PresetSummary
	for i := range list {
		if list[i].ID == id {
			found = &list[i]
			break
		}
	}
	if found == nil {
		http.NotFound(w, r)
		return
	}

	data := presetData{
		Preset:           found.Preset,
		Fields:           defaultFields(),
		AdminPasswordSet: found.AdminPasswordSet,
	}

	if password, perr := s.DB.PresetAdminPassword(r.Context(), id); perr == nil {
		data.AdminPassword = password
	}

	revision, err := s.DB.LatestRevision(r.Context(), id)
	switch {
	case err == nil:
		data.Revision = revision
		data.HasSaved = true
		if parsed, perr := preset.Parse(revision.Payload); perr == nil {
			data.Fields = fillGaps(parsed)
		} else {
			data.Problems = []string{"Сохранённая ревизия не читается: " + perr.Error()}
		}
	case errors.Is(err, storage.ErrNotFound):
		// Ревизий ещё нет — форма показывает заводские значения, и первое
		// сохранение станет первой ревизией.
	default:
		s.fail(w, err)
		return
	}

	revisions, err := s.DB.ListRevisions(r.Context(), id)
	if err != nil {
		s.fail(w, err)
		return
	}
	data.Revisions = revisions
	// Кого касается предустановка, нужно знать всегда, а не только перед
	// выкладкой: этим же числом «Убрать» объясняет, почему она недоступна.
	if data.Employees, data.Machines, err = s.DB.PresetReach(r.Context(), id); err != nil {
		s.fail(w, err)
		return
	}

	data.NeedsPublish = data.HasSaved && !data.Revision.Published()
	if data.NeedsPublish {
		data.Pending, data.Trouble, data.FirstPublish = s.pendingChanges(r, id, data.Revision)
	}
	data.DangerousRollback = s.dangerousRollbacks(data.Fields, revisions)

	// Подставленный раздел показывается поверх сохранённого — но только в
	// форме: сравнение с выложенным и список ревизий остаются про то, что
	// действительно лежит в базе.
	if override != nil {
		data.Fields = *override
	}
	data.Others = otherPresets(list, id)

	s.render(w, r, view, page{
		Title: found.Name, Section: "presets", Admin: admin, Data: data,
	})
}

// pendingChanges перечисляет словами, что уедет на машины при выкладке.
//
// Возвращает ещё и признак «выкладок не было»: на первой выкладке сравнивать
// не с чем, и пустой список изменений там означал бы «ничего не поменяется» —
// ровно наоборот тому, что произойдёт.
func (s *Server) pendingChanges(r *http.Request, presetID int64, latest model.PresetRevision) (preset.Report, string, bool) {
	published, err := s.DB.LastPublishedRevision(r.Context(), presetID)
	if errors.Is(err, storage.ErrNotFound) {
		return preset.Report{}, "", true
	}
	if err != nil {
		return preset.Report{}, "Не удалось сравнить с выложенной ревизией: " + err.Error(), false
	}

	before, berr := preset.Parse(published.Payload)
	after, aerr := preset.Parse(latest.Payload)
	if berr != nil || aerr != nil {
		// Ревизия из будущей схемы: строгий разбор её не берёт. Молчать нельзя —
		// человек прочтёт пустой список как «ничего не меняется».
		return preset.Report{}, "Сравнить не с чем: одна из ревизий собрана схемой, которой эта панель не знает", false
	}
	return preset.Grouped(before, after), "", false
}

// dangerousRollbacks помечает ревизии, откат на которые трогает адреса АТС,
// стук или доверие к сертификату.
//
// Откат остаётся мгновенным — правку готовят заранее, а откатываются, когда на
// рабочих местах уже сломалось, и второе нажатие в этот момент издевательство.
// Но у отката, который меняет адрес АТС, цена ошибки та же, что у выкладки, а
// окна выкладки он не проходит вовсе. Подтверждение спрашивается только у них.
func (s *Server) dangerousRollbacks(current preset.Fields, revisions []storage.RevisionRow) map[int64]bool {
	out := make(map[int64]bool, len(revisions))
	for _, row := range revisions {
		target, err := preset.Parse(row.Payload)
		if err != nil {
			// Разобрать не смогли — считаем опасным: спросить лишний раз
			// дешевле, чем молча увезти на машины неизвестно что.
			out[row.ID] = true
			continue
		}
		out[row.ID] = len(preset.Grouped(current, fillGaps(target)).Dangerous) > 0
	}
	return out
}

// rollback возвращает предустановку к прежней ревизии.
//
// Новой ревизией поверх, а не правкой прошлого: череда ревизий — это история,
// и переписывать её значило бы терять ответ на «что стояло на машинах в
// прошлый вторник».
//
// Выкладывается сразу, и это намеренное исключение из правила «сохранить и
// выложить — разные нажатия». Правку готовят заранее, а откатываются, когда на
// рабочих местах уже что-то сломалось; требовать в этот момент второго нажатия
// — издевательство.
func (s *Server) rollback(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	card := "/presets/" + strconv.FormatInt(id, 10)

	target, err := strconv.ParseInt(r.FormValue("revision_id"), 10, 64)
	if err != nil {
		s.flash(r, "bad", "Не откачено", "Непонятная ревизия")
		s.back(w, r, card)
		return
	}

	source, err := s.DB.RevisionByID(r.Context(), target)
	if err != nil || source.PresetID != id {
		s.flash(r, "bad", "Не откачено", "Такой ревизии у этой предустановки нет")
		s.back(w, r, card)
		return
	}

	created, err := s.DB.SaveRevision(r.Context(), actorOf(admin), id,
		source.SchemaVersion, source.Payload,
		"откат на ревизию "+strconv.Itoa(source.Revision))
	if err != nil {
		s.flash(r, "bad", "Не откачено", friendly(err))
		s.back(w, r, card)
		return
	}

	if _, err := s.Publisher.PublishOnly(r.Context(), actorOf(admin), id); err != nil {
		// Ревизия уже сохранена, и делать вид, что отката не было, нельзя:
		// следующая выкладка увезёт именно её.
		s.flash(r, "bad", "Откат сохранён, но не выложен",
			"Ревизия "+strconv.Itoa(created.Revision)+" лежит в базе — нажмите «Выложить». Причина: "+err.Error())
		s.back(w, r, card)
		return
	}

	s.flash(r, "ok",
		"Откачено на ревизию "+strconv.Itoa(source.Revision),
		"Сохранено ревизией "+strconv.Itoa(created.Revision)+" и выложено сразу — машины подхватят в течение получаса.")
	s.back(w, r, card)
}

func (s *Server) savePreset(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		s.flash(r, "bad", "Не сохранено", "Форма не разобралась")
		s.back(w, r, "/presets")
		return
	}

	fields, err := fieldsFromForm(r)
	if err != nil {
		s.flash(r, "bad", "Не сохранено", err.Error())
		s.back(w, r, "/presets/"+strconv.FormatInt(id, 10))
		return
	}

	// Проверка до сохранения, а не после: сохранённая ревизия уезжает на все
	// рабочие места обязательным обновлением, и это последнее место, где
	// опечатку ещё можно показать человеку.
	if problems := fields.Validate(); len(problems) > 0 {
		text := make([]string, 0, len(problems))
		for _, p := range problems {
			text = append(text, p.Error())
		}
		s.flash(r, "bad", "Не сохранено — проверьте поля", strings.Join(text, "; "))
		s.back(w, r, "/presets/"+strconv.FormatInt(id, 10))
		return
	}

	payload, err := fields.Canonical()
	if err != nil {
		s.flash(r, "bad", "Не сохранено", err.Error())
		s.back(w, r, "/presets/"+strconv.FormatInt(id, 10))
		return
	}

	revision, err := s.DB.SaveRevision(r.Context(), actorOf(admin), id,
		preset.SchemaVersion, payload, strings.TrimSpace(r.FormValue("note")))
	if err != nil {
		s.flash(r, "bad", "Не сохранено", friendly(err))
		s.back(w, r, "/presets/"+strconv.FormatInt(id, 10))
		return
	}

	s.flash(r, "ok", "Ревизия "+strconv.Itoa(revision.Revision)+" сохранена",
		"На машины она попадёт после выкладки — нажмите «Выложить».")
	http.Redirect(w, r, "/presets/"+strconv.FormatInt(id, 10), http.StatusSeeOther)
}

// publishPreset выкладывает одну предустановку.
//
// Главный путь выкладки. Общая кнопка «Выложить все» осталась на списке, но
// она — исключение: обычная правка касается одной предустановки, и увозить с
// ней чужие сохранённые ревизии незачем.
func (s *Server) publishPreset(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	card := "/presets/" + strconv.FormatInt(id, 10)

	if _, err := s.Publisher.PublishOnly(r.Context(), actorOf(admin), id); err != nil {
		s.flash(r, "bad", "Не выложено", err.Error())
		s.back(w, r, card)
		return
	}

	s.flash(r, "ok", "Выложено",
		"Машины подхватят изменения в течение получаса — обновление предустановки обязательное, откладывать его нельзя. Оно ждёт только конца разговора. Невыложенные правки других предустановок остались невыложенными.")
	s.back(w, r, card)
}

// deletePreset убирает предустановку из работы.
//
// Отдельным действием внизу карточки, как и удаление сотрудника: прокрутив
// список ревизий, человек оказывается прямо над ним, и попасть сюда случайно
// с верхних кнопок нельзя.
func (s *Server) deletePreset(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	card := "/presets/" + strconv.FormatInt(id, 10)

	switch err := s.DB.ArchivePreset(r.Context(), actorOf(admin), id); {
	case err == nil:
		s.flash(r, "ok", "Предустановка убрана",
			"В файл предустановок она больше не попадает. Машины, на которых она стояла, останутся с последними применёнными настройками — панель их больше не меняет.")
		http.Redirect(w, r, "/presets", http.StatusSeeOther)
		return
	case errors.Is(err, storage.ErrPresetInUse):
		s.flash(r, "bad", "Не убрана",
			"За ней ещё числятся сотрудники. Переведите их на другую предустановку — иначе ключ им будет не из чего собрать.")
	case errors.Is(err, storage.ErrNotFound):
		s.flash(r, "bad", "Не убрана", "Такой предустановки нет или она уже убрана")
	default:
		s.flash(r, "bad", "Не убрана", friendly(err))
	}
	s.back(w, r, card)
}

func (s *Server) publish(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	bundle, err := s.Publisher.Publish(r.Context(), actorOf(admin))
	if err != nil {
		s.flash(r, "bad", "Не выложено", err.Error())
		s.back(w, r, "/presets")
		return
	}

	count := len(bundle.Presets)
	s.flash(r, "ok",
		"Выложено: "+strconv.Itoa(count)+" "+pluralPreset(count),
		"Машины подхватят изменения в течение получаса — обновление предустановки обязательное, откладывать его нельзя. Оно ждёт только конца разговора.")
	s.back(w, r, "/presets")
}

func pluralPreset(n int) string {
	switch {
	case n%100 >= 11 && n%100 <= 14:
		return "предустановок"
	case n%10 == 1:
		return "предустановка"
	case n%10 >= 2 && n%10 <= 4:
		return "предустановки"
	default:
		return "предустановок"
	}
}

// ------------------------------------------------------- разбор формы

// defaultFields — с чего начинается новая предустановка.
//
// Заводские значения приложения, а не пустота: пустая форма заставила бы
// администратора выдумывать длительность тона DTMF, а правильный ответ на это
// уже есть в коде клиента.
func defaultFields() preset.Fields {
	no := false
	return preset.Fields{
		DTMF: &preset.DTMF{
			ToneMilliseconds: 120, GapMilliseconds: 80, PauseMilliseconds: 500,
			MacroColumns: 3, MacroHeight: 58,
		},
		IncomingCall: &preset.CallGuard{
			IsEnabled: true, IsRandomPositionEnabled: true,
			MinimumTravel: 150, ScreenMargin: 24, TargetCount: 1,
			RequiredCursorTravel: 120, RequiredCursorSamples: 6,
		},
		Queues:      &preset.Queues{},
		Conference:  &preset.Conference{FeatureCode: "*3", RoomExtension: "8000"},
		SiteAddress: &preset.SiteAddresses{Office: "192.168.1.2", Remote: "crm.elitesochi.com"},
		PortKnock: &preset.PortKnock{
			Steps: []preset.KnockStep{
				{PayloadBytes: 228, Count: 2},
				{PayloadBytes: 126, Count: 2},
				{PayloadBytes: 125, Count: 1},
				{Host: "45.10.53.84", PayloadBytes: 228, Count: 1},
				{Host: "45.10.53.86", PayloadBytes: 126, Count: 1},
				{Host: "45.10.53.94", PayloadBytes: 125, Count: 1},
			},
			SpacingSeconds: 1, RepeatIntervalSeconds: 600,
		},
		AcceptsAnyTLSCertificate: &no,
	}
}

// fillGaps достраивает то, чего нет в сохранённой ревизии.
//
// Нужно форме, а не файлу: отсутствующее поле означает «панель им не
// управляет», и в файл оно так и не попадёт — но показать в форме что-то надо,
// иначе строка ввода будет пустой без объяснения.
func fillGaps(f preset.Fields) preset.Fields {
	d := defaultFields()
	if f.DTMF == nil {
		f.DTMF = d.DTMF
	}
	if f.IncomingCall == nil {
		f.IncomingCall = d.IncomingCall
	}
	if f.Queues == nil {
		f.Queues = d.Queues
	}
	if f.Conference == nil {
		f.Conference = d.Conference
	}
	if f.SiteAddress == nil {
		f.SiteAddress = d.SiteAddress
	}
	if f.PortKnock == nil {
		f.PortKnock = d.PortKnock
	}
	if f.AcceptsAnyTLSCertificate == nil {
		f.AcceptsAnyTLSCertificate = d.AcceptsAnyTLSCertificate
	}
	return f
}

func fieldsFromForm(r *http.Request) (preset.Fields, error) {
	trust := checkbox(r, "acceptsAnyTLSCertificate")

	fields := preset.Fields{
		DTMF: &preset.DTMF{
			ToneMilliseconds:    intField(r, "toneMilliseconds"),
			GapMilliseconds:     intField(r, "gapMilliseconds"),
			PauseMilliseconds:   intField(r, "pauseMilliseconds"),
			MacroColumns:        intField(r, "macroColumns"),
			MacroHeight:         intField(r, "macroHeight"),
			MacroHeightIsManual: checkbox(r, "macroHeightIsManual"),
		},
		IncomingCall: &preset.CallGuard{
			IsEnabled:               checkbox(r, "guardEnabled"),
			IsRandomPositionEnabled: checkbox(r, "randomPosition"),
			TunesRandomnessByHand:   checkbox(r, "tunesRandomness"),
			MinimumTravel:           floatField(r, "minimumTravel"),
			ScreenMargin:            floatField(r, "screenMargin"),
			TargetCount:             intField(r, "targetCount"),
			RequiresCursorMovement:  checkbox(r, "requiresCursor"),
			TunesLivenessByHand:     checkbox(r, "tunesLiveness"),
			RequiredCursorTravel:    floatField(r, "cursorTravel"),
			RequiredCursorSamples:   intField(r, "cursorSamples"),
			RejectsSyntheticEvents:  checkbox(r, "rejectsSynthetic"),
		},
		Conference: &preset.Conference{
			FeatureCode:   strings.TrimSpace(r.FormValue("featureCode")),
			RoomExtension: strings.TrimSpace(r.FormValue("roomExtension")),
		},
		SiteAddress: &preset.SiteAddresses{
			Office: strings.TrimSpace(r.FormValue("office")),
			Remote: strings.TrimSpace(r.FormValue("remote")),
		},
		PortKnock: &preset.PortKnock{
			SpacingSeconds:        floatField(r, "spacingSeconds"),
			RepeatIntervalSeconds: floatField(r, "repeatIntervalSeconds"),
		},
		Queues:                   &preset.Queues{},
		AcceptsAnyTLSCertificate: &trust,
	}

	// Строки собираются по списку индексов, а не по позиции в форме: удаление
	// строки в браузере не должно перенумеровывать остальные, иначе
	// одновременная правка двух строк даёт перепутанные значения.
	for _, index := range r.Form["macroIndex"] {
		id := strings.TrimSpace(r.FormValue("macroID_" + index))
		title := strings.TrimSpace(r.FormValue("macroTitle_" + index))
		sequence := strings.TrimSpace(r.FormValue("macroSequence_" + index))
		if title == "" && sequence == "" {
			continue
		}
		if id == "" {
			fresh, err := preset.NewID()
			if err != nil {
				return preset.Fields{}, err
			}
			id = fresh
		}
		fields.DTMF.Macros = append(fields.DTMF.Macros, preset.Macro{
			ID: id, Title: title, Sequence: sequence,
			TransfersCall: checkbox(r, "macroTransfers_"+index),
		})
	}

	for _, index := range r.Form["queueIndex"] {
		id := strings.TrimSpace(r.FormValue("queueID_" + index))
		number := strings.TrimSpace(r.FormValue("queueNumber_" + index))
		title := strings.TrimSpace(r.FormValue("queueTitle_" + index))
		if number == "" && title == "" {
			continue
		}
		if id == "" {
			fresh, err := preset.NewID()
			if err != nil {
				return preset.Fields{}, err
			}
			id = fresh
		}
		fields.Queues.Queues = append(fields.Queues.Queues,
			preset.Queue{ID: id, Number: number, Title: title})
	}

	for _, index := range r.Form["knockIndex"] {
		bytes := intField(r, "knockBytes_"+index)
		count := intField(r, "knockCount_"+index)
		if bytes == 0 && count == 0 {
			continue
		}
		fields.PortKnock.Steps = append(fields.PortKnock.Steps, preset.KnockStep{
			Host:         strings.TrimSpace(r.FormValue("knockHost_" + index)),
			PayloadBytes: bytes,
			Count:        count,
		})
	}
	return fields, nil
}

// checkbox читает последнее значение поля.
//
// Последнее, а не первое: рядом с каждым переключателем стоит скрытое поле со
// значением «нет». Без него выключенный переключатель не отправляется вовсе, и
// выключить что-либо было бы невозможно — форма читала бы прежнее значение.
func checkbox(r *http.Request, name string) bool {
	values := r.Form[name]
	if len(values) == 0 {
		return false
	}
	return values[len(values)-1] == "1"
}

func intField(r *http.Request, name string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(r.FormValue(name)))
	return n
}

func floatField(r *http.Request, name string) float64 {
	raw := strings.TrimSpace(r.FormValue(name))
	// Запятая как разделитель дробной части: её вводят на русской раскладке, и
	// отказ из-за неё выглядел бы придиркой.
	raw = strings.ReplaceAll(raw, ",", ".")
	f, _ := strconv.ParseFloat(raw, 64)
	return f
}

// otherPresets — все, кроме этой, и только с сохранёнными ревизиями: у пустой
// брать нечего.
func otherPresets(list []storage.PresetSummary, id int64) []storage.PresetSummary {
	out := make([]storage.PresetSummary, 0, len(list))
	for _, p := range list {
		if p.ID != id && p.Revision > 0 {
			out = append(out, p)
		}
	}
	return out
}
