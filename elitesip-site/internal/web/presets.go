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
	// Сам пароль на страницу не едет: показывать его незачем, а задать новый
	// можно и вслепую.
	AdminPasswordSet bool

	Revisions []storage.RevisionRow

	// Pending — что уедет на машины при следующей выкладке, словами.
	//
	// Считается от последней выложенной ревизии, а не от предыдущей
	// сохранённой: сравнивать надо с тем, что сейчас стоит на машинах.
	Pending      []string
	NeedsPublish bool

	// FirstPublish — выкладок ещё не было, сравнивать не с чем.
	FirstPublish bool
}

func (s *Server) showPreset(w http.ResponseWriter, r *http.Request, admin model.Admin) {
	id, err := pathID(r)
	if err != nil {
		http.NotFound(w, r)
		return
	}

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
	data.NeedsPublish = data.HasSaved && !data.Revision.Published()
	if data.NeedsPublish {
		data.Pending, data.FirstPublish = s.pendingChanges(r, id, data.Revision)
	}

	s.render(w, r, "preset", page{
		Title: found.Name, Section: "presets", Admin: admin, Data: data,
	})
}

// pendingChanges перечисляет словами, что уедет на машины при выкладке.
//
// Возвращает ещё и признак «выкладок не было»: на первой выкладке сравнивать
// не с чем, и пустой список изменений там означал бы «ничего не поменяется» —
// ровно наоборот тому, что произойдёт.
func (s *Server) pendingChanges(r *http.Request, presetID int64, latest model.PresetRevision) ([]string, bool) {
	published, err := s.DB.LastPublishedRevision(r.Context(), presetID)
	if errors.Is(err, storage.ErrNotFound) {
		return nil, true
	}
	if err != nil {
		return []string{"Не удалось сравнить с выложенной ревизией: " + err.Error()}, false
	}

	before, berr := preset.Parse(published.Payload)
	after, aerr := preset.Parse(latest.Payload)
	if berr != nil || aerr != nil {
		// Ревизия из будущей схемы: строгий разбор её не берёт. Молчать нельзя —
		// человек прочтёт пустой список как «ничего не меняется».
		return []string{"Сравнить не с чем: одна из ревизий собрана схемой, которой эта панель не знает"}, false
	}
	return preset.Changes(before, after), false
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

	if _, err := s.Publisher.Publish(r.Context(), actorOf(admin)); err != nil {
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
