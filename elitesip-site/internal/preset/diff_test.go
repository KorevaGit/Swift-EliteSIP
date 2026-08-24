package preset

import (
	"strings"
	"testing"
)

func base() Fields {
	no := false
	return Fields{
		DTMF: &DTMF{
			ToneMilliseconds: 120, GapMilliseconds: 80, PauseMilliseconds: 500,
			MacroColumns: 3, MacroHeight: 58,
			Macros: []Macro{
				{ID: "a", Title: "ЮРИСТ", Sequence: "*02,101", TransfersCall: true},
				{ID: "b", Title: "СКЛАД", Sequence: "*02,110", TransfersCall: true},
			},
		},
		IncomingCall: &CallGuard{IsEnabled: true, MinimumTravel: 150, TargetCount: 1},
		Queues:       &Queues{Queues: []Queue{{ID: "q", Number: "1000", Title: "Раздача"}}},
		Conference:   &Conference{FeatureCode: "*3", RoomExtension: "8000"},
		SiteAddress:  &SiteAddresses{Office: "192.168.1.2", Remote: "crm.elitesochi.com"},
		PortKnock: &PortKnock{
			Steps:          []KnockStep{{PayloadBytes: 228, Count: 2}},
			SpacingSeconds: 1, RepeatIntervalSeconds: 600,
		},
		AcceptsAnyTLSCertificate: &no,
	}
}

// Правка одного макроса даёт ровно одну строку — иначе список перестают читать.
func TestOneMacroEditGivesOneLine(t *testing.T) {
	before := base()
	after := base()
	after.DTMF.Macros[0].Sequence = "*02,105"

	changes := Changes(before, after)
	if len(changes) != 1 {
		t.Fatalf("строк %d, ожидалась 1: %v", len(changes), changes)
	}
	if changes[0] != "Клавиша «ЮРИСТ»: набор «*02,101» → «*02,105»" {
		t.Errorf("строка вышла такая: %q", changes[0])
	}
}

func TestNoChangesGivesEmptyList(t *testing.T) {
	if changes := Changes(base(), base()); len(changes) != 0 {
		t.Errorf("на одинаковых ревизиях нашлось: %v", changes)
	}
}

// Вставка клавиши в середину не должна показывать изменившимися все, что ниже:
// сличение идёт по идентификатору, а не по месту в списке.
func TestInsertedMacroDoesNotShiftTheRest(t *testing.T) {
	before := base()
	after := base()
	after.DTMF.Macros = []Macro{
		after.DTMF.Macros[0],
		{ID: "c", Title: "БУХГАЛТЕРИЯ", Sequence: "*02,120"},
		after.DTMF.Macros[1],
	}

	changes := Changes(before, after)
	if len(changes) != 1 {
		t.Fatalf("строк %d, ожидалась 1: %v", len(changes), changes)
	}
	if !strings.Contains(changes[0], "«БУХГАЛТЕРИЯ» добавлена") {
		t.Errorf("строка вышла такая: %q", changes[0])
	}
}

func TestRemovedMacroIsNamed(t *testing.T) {
	before := base()
	after := base()
	after.DTMF.Macros = after.DTMF.Macros[:1]

	changes := Changes(before, after)
	if len(changes) != 1 || !strings.Contains(changes[0], "«СКЛАД» удалена") {
		t.Errorf("удаление показано так: %v", changes)
	}
}

// Самое опасное, что возит эта линия.
func TestAddressChangeShowsBothValues(t *testing.T) {
	before := base()
	after := base()
	after.SiteAddress.Remote = "crm2.elitesochi.com"

	changes := Changes(before, after)
	if len(changes) != 1 {
		t.Fatalf("строк %d: %v", len(changes), changes)
	}
	if !strings.Contains(changes[0], "снаружи") ||
		!strings.Contains(changes[0], "crm.elitesochi.com") ||
		!strings.Contains(changes[0], "crm2.elitesochi.com") {
		t.Errorf("строка вышла такая: %q", changes[0])
	}
}

// Единственное изменение, ослабляющее защиту, должно кричать.
func TestEnablingBlindTLSTrustIsShouted(t *testing.T) {
	before := base()
	after := base()
	yes := true
	after.AcceptsAnyTLSCertificate = &yes

	changes := Changes(before, after)
	if len(changes) != 1 || !strings.Contains(changes[0], "ВКЛЮЧЕНО") {
		t.Errorf("включение доверия показано так: %v", changes)
	}
}

// «Панель перестала управлять» и «значение поменялось» — разные вещи: в первом
// случае машина сохранит своё текущее, а не применит новое.
func TestDroppedSectionSaysWhoKeepsTheValue(t *testing.T) {
	before := base()
	after := base()
	after.Queues = nil

	changes := Changes(before, after)
	if len(changes) != 1 || !strings.Contains(changes[0], "перестаёт этим управлять") {
		t.Fatalf("уход раздела показан так: %v", changes)
	}
	if !strings.Contains(changes[0], "сохранят своё текущее") {
		t.Errorf("не сказано, что будет со значением на машинах: %q", changes[0])
	}
}

// Стук показывается целиком: у шага нет имени, и «шаг 3 изменился» человеку
// ничего не сообщает.
func TestKnockStepsAreDescribedAsAWhole(t *testing.T) {
	before := base()
	after := base()
	after.PortKnock.Steps = append(after.PortKnock.Steps, KnockStep{PayloadBytes: 126, Count: 1})

	changes := Changes(before, after)
	if len(changes) != 1 || !strings.Contains(changes[0], "было 1 шаг, стало 2") {
		t.Errorf("стук показан так: %v", changes)
	}
}

// Дробные значения печатаются без хвостовых нулей: «1 с», а не «1.000000 с».
func TestFloatsPrintWithoutTrailingZeros(t *testing.T) {
	before := base()
	after := base()
	after.PortKnock.SpacingSeconds = 1.5

	changes := Changes(before, after)
	if len(changes) != 1 || changes[0] != "Промежуток между шагами стука: 1 с → 1.5 с" {
		t.Errorf("строка вышла такая: %v", changes)
	}
}
