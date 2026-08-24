package preset

import (
	"encoding/json"
	"strings"
	"testing"
)

func mustID(t *testing.T) string {
	t.Helper()
	id, err := NewID()
	if err != nil {
		t.Fatalf("NewID: %v", err)
	}
	return id
}

func validFields(t *testing.T) Fields {
	t.Helper()
	no := false

	return Fields{
		DTMF: &DTMF{
			ToneMilliseconds:  120,
			GapMilliseconds:   80,
			PauseMilliseconds: 500,
			MacroColumns:      3,
			MacroHeight:       58,
			Macros: []Macro{
				{ID: mustID(t), Title: "ЮРИСТ", Sequence: "*02,101", TransfersCall: true},
			},
		},
		IncomingCall: &CallGuard{
			IsEnabled:               true,
			IsRandomPositionEnabled: true,
			MinimumTravel:           150,
			ScreenMargin:            24,
			TargetCount:             1,
		},
		Queues: &Queues{Queues: []Queue{
			{ID: mustID(t), Number: "2929", Title: "Горячий лид"},
		}},
		Conference:  &Conference{FeatureCode: "*3", RoomExtension: "8000"},
		SiteAddress: &SiteAddresses{Office: "192.168.1.2", Remote: "crm.elitesochi.com"},
		PortKnock: &PortKnock{
			Steps: []KnockStep{
				{PayloadBytes: 228, Count: 2},
				{Host: "45.10.53.84", PayloadBytes: 228, Count: 1},
			},
			SpacingSeconds:        1,
			RepeatIntervalSeconds: 600,
		},
		AcceptsAnyTLSCertificate: &no,
	}
}

func TestValidFieldsPass(t *testing.T) {
	if problems := validFields(t).Validate(); len(problems) != 0 {
		t.Fatalf("боевой набор не прошёл проверку: %v", problems)
	}
}

// Пустой набор допустим: «панель ничем не управляет» — это законное состояние,
// при котором машина сохраняет всё своё.
func TestEmptyFieldsPass(t *testing.T) {
	if problems := (Fields{}).Validate(); len(problems) != 0 {
		t.Fatalf("пустой набор не прошёл проверку: %v", problems)
	}
}

// Отсутствующее поле и поле со значением — разные вещи, и в файле это должно
// быть видно.
func TestOmittedFieldsStayOutOfJSON(t *testing.T) {
	data, err := Fields{Conference: &Conference{FeatureCode: "*3", RoomExtension: "8000"}}.Canonical()
	if err != nil {
		t.Fatalf("Canonical: %v", err)
	}
	text := string(data)

	if !strings.Contains(text, "conference") {
		t.Error("заданное поле пропало из файла")
	}
	for _, absent := range []string{"dtmf", "queues", "portKnock", "siteAddresses", "acceptsAnyTLSCertificate"} {
		if strings.Contains(text, absent) {
			t.Errorf("незаданное поле %q попало в файл: %s", absent, text)
		}
	}
}

// Опечатка в имени поля должна остановиться в панели, а не уехать на машины.
func TestParseRejectsUnknownFields(t *testing.T) {
	_, err := Parse([]byte(`{"conferense":{"featureCode":"*3"}}`))
	if err == nil {
		t.Fatal("опечатка в имени поля прошла")
	}
}

func TestParseRoundTrip(t *testing.T) {
	fields := validFields(t)

	data, err := fields.Canonical()
	if err != nil {
		t.Fatalf("Canonical: %v", err)
	}
	back, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	again, err := back.Canonical()
	if err != nil {
		t.Fatalf("повторный Canonical: %v", err)
	}
	if string(again) != string(data) {
		t.Errorf("после разбора и сборки получилось другое:\n%s\n%s", data, again)
	}
}

func TestDTMFLimitsMatchApplication(t *testing.T) {
	cases := map[string]func(*DTMF){
		"клавиш в ряду":     func(d *DTMF) { d.MacroColumns = 5 },
		"высота клавиши":    func(d *DTMF) { d.MacroHeight = 120 },
		"длительность тона": func(d *DTMF) { d.ToneMilliseconds = 12 },
	}
	for name, spoil := range cases {
		fields := validFields(t)
		spoil(fields.DTMF)

		problems := fields.Validate()
		if len(problems) == 0 {
			t.Errorf("%s: нарушение предела прошло", name)
			continue
		}
		if !strings.Contains(problems[0].Error(), name) {
			t.Errorf("%s: сообщение не о том — %v", name, problems[0])
		}
	}
}

func TestTooManyMacrosRejected(t *testing.T) {
	fields := validFields(t)
	for len(fields.DTMF.Macros) <= maximumMacros {
		fields.DTMF.Macros = append(fields.DTMF.Macros,
			Macro{ID: mustID(t), Title: "КЛАВИША", Sequence: "1"})
	}

	if problems := fields.Validate(); len(problems) == 0 {
		t.Fatal("девятнадцать клавиш прошли проверку")
	}
}

func TestSequenceMustBeDialable(t *testing.T) {
	fields := validFields(t)
	fields.DTMF.Macros[0].Sequence = "10Z"

	problems := fields.Validate()
	if len(problems) == 0 {
		t.Fatal("недопустимый знак в наборе прошёл")
	}
	if !strings.Contains(problems[0].Error(), "не набирается тоном") {
		t.Errorf("сообщение: %v", problems[0])
	}
}

// Половина записи очереди хуже её отсутствия: номер без названия убирает номер
// из окна входящего и не даёт взамен ничего.
func TestQueueHalfFilledRejected(t *testing.T) {
	fields := validFields(t)
	fields.Queues.Queues[0].Title = "   "

	if problems := fields.Validate(); len(problems) == 0 {
		t.Fatal("очередь без названия прошла")
	}
}

func TestDuplicateQueueNumberRejected(t *testing.T) {
	fields := validFields(t)
	fields.Queues.Queues = append(fields.Queues.Queues,
		Queue{ID: mustID(t), Number: "29 29", Title: "Другая"})

	problems := fields.Validate()
	if len(problems) == 0 {
		t.Fatal("две очереди на одном номере прошли")
	}
	if !strings.Contains(problems[0].Error(), "уже занят") {
		t.Errorf("сообщение: %v", problems[0])
	}
}

// Совпавшие адреса означают, что переключатель «офис ↔ дом» ничего не
// переключает. Это почти всегда недозаполненная форма.
func TestSameAddressesRejected(t *testing.T) {
	fields := validFields(t)
	fields.SiteAddress.Remote = fields.SiteAddress.Office

	if problems := fields.Validate(); len(problems) == 0 {
		t.Fatal("одинаковые адреса прошли")
	}
}

func TestEmptyAddressRejected(t *testing.T) {
	fields := validFields(t)
	fields.SiteAddress.Remote = ""

	if problems := fields.Validate(); len(problems) == 0 {
		t.Fatal("пустой адрес АТС прошёл")
	}
}

// Включённое требование движения курсора с нулевым порогом — защита, которая
// выглядит работающей и не работает.
func TestCursorGuardWithoutThresholdRejected(t *testing.T) {
	fields := validFields(t)
	fields.IncomingCall.RequiresCursorMovement = true
	fields.IncomingCall.RequiredCursorTravel = 0
	fields.IncomingCall.RequiredCursorSamples = 1

	problems := fields.Validate()
	if len(problems) < 2 {
		t.Fatalf("проверок сработало %d, ожидалось две: %v", len(problems), problems)
	}
}

// Пустой стук допустим: так его выключают.
func TestEmptyKnockIsAllowed(t *testing.T) {
	fields := validFields(t)
	fields.PortKnock.Steps = nil

	if problems := fields.Validate(); len(problems) != 0 {
		t.Fatalf("выключенный стук не прошёл: %v", problems)
	}
}

func TestKnockLimits(t *testing.T) {
	fields := validFields(t)
	fields.PortKnock.RepeatIntervalSeconds = 5

	if problems := fields.Validate(); len(problems) == 0 {
		t.Fatal("повтор стука раз в пять секунд прошёл")
	}
}

// Форма должна показать всё, что не так, разом.
func TestValidateReportsEveryProblem(t *testing.T) {
	fields := validFields(t)
	fields.DTMF.MacroColumns = 9
	fields.Conference.FeatureCode = ""
	fields.SiteAddress.Office = ""

	problems := fields.Validate()
	if len(problems) < 3 {
		t.Fatalf("найдено %d бед, ожидалось не меньше трёх: %v", len(problems), problems)
	}
}

func TestNewIDLooksLikeSwiftUUID(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 100; i++ {
		id := mustID(t)
		if err := validateID("проверка", id); err != nil {
			t.Fatalf("свой же идентификатор не прошёл проверку: %v", err)
		}
		if id != strings.ToUpper(id) {
			t.Fatalf("идентификатор не в верхнем регистре: %q", id)
		}
		if id[14] != '4' {
			t.Fatalf("не UUID версии 4: %q", id)
		}
		if seen[id] {
			t.Fatalf("идентификатор повторился: %q", id)
		}
		seen[id] = true
	}
}

// Набор должен разбираться тем же JSON, каким его читает приложение: имена
// полей — часть контракта, и молчаливое переименование сломает клиента.
func TestFieldNamesMatchContract(t *testing.T) {
	data, err := validFields(t).Canonical()
	if err != nil {
		t.Fatalf("Canonical: %v", err)
	}

	var generic map[string]json.RawMessage
	if err := json.Unmarshal(data, &generic); err != nil {
		t.Fatalf("разобрать: %v", err)
	}

	for _, key := range []string{
		"dtmf", "incomingCall", "queues", "conference",
		"portKnock", "siteAddresses", "acceptsAnyTLSCertificate",
	} {
		if _, ok := generic[key]; !ok {
			t.Errorf("в файле нет поля %q", key)
		}
	}
}
