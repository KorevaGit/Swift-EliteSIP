package sand

import (
	"strings"
	"testing"
)

// Списки шаблона, по которым идёт большинство проверок: оба уровня работ в
// обоих форматах песка.
func allTaskLists() map[string][]Task {
	return map[string][]Task{
		"песок, офис":       SandboxTasks(Office),
		"песок, удалёнка":   SandboxTasks(Remote),
		"человек, офис":     EmployeeTasks(Office),
		"человек, удалёнка": EmployeeTasks(Remote),
	}
}

// Зависимость на несуществующий ключ — это работа, которую нельзя отметить
// никогда: сервер будет ждать отметки, которой неоткуда взяться.
func TestDependenciesPointToExistingTasks(t *testing.T) {
	for name, tasks := range allTaskLists() {
		keys := make(map[string]bool, len(tasks))
		for _, task := range tasks {
			keys[task.Key] = true
		}
		for _, task := range tasks {
			for _, need := range task.Needs {
				if !keys[need] {
					t.Errorf("%s: %q зависит от %q, а такой работы в списке нет", name, task.Key, need)
				}
				if need == task.Key {
					t.Errorf("%s: %q зависит от самой себя", name, task.Key)
				}
			}
		}
	}
}

// Цикл в графе означает, что ни одну работу кольца отметить нельзя: каждая
// ждёт следующую. Найтись он может только здесь — на экране это выглядит как
// молча не срабатывающая кнопка.
func TestNoCyclesInDependencies(t *testing.T) {
	for name, tasks := range allTaskLists() {
		needs := make(map[string][]string, len(tasks))
		for _, task := range tasks {
			needs[task.Key] = task.Needs
		}

		const (
			untouched = 0
			inProcess = 1
			done      = 2
		)
		state := make(map[string]int, len(tasks))

		var walk func(key string, path []string) bool
		walk = func(key string, path []string) bool {
			switch state[key] {
			case done:
				return false
			case inProcess:
				t.Errorf("%s: зависимости замкнулись в кольцо: %s → %s",
					name, strings.Join(path, " → "), key)
				return true
			}

			state[key] = inProcess
			for _, need := range needs[key] {
				if walk(need, append(path, key)) {
					return true
				}
			}
			state[key] = done
			return false
		}

		for _, task := range tasks {
			if walk(task.Key, nil) {
				break
			}
		}
	}
}

// Ключи — имена столбца task в таблицах отметок. Разойдясь с MODEL.md, они
// разойдутся и с уже проставленными отметками в базе.
func TestKeysMatchTheModel(t *testing.T) {
	want := map[string][]string{
		"песок":   {"extensions", "hardware", "keys", "libra", "seized"},
		"человек": {"bitrix", "libra", "extension", "base_filled", "inventory", "outcome", "base_drained", "rusguard"},
	}

	got := map[string][]string{
		"песок":   keysOf(SandboxTasks(Office)),
		"человек": keysOf(EmployeeTasks(Office)),
	}

	for level, wantKeys := range want {
		gotKeys := got[level]
		if len(gotKeys) != len(wantKeys) {
			t.Fatalf("%s: работ %d, в модели %d: %v", level, len(gotKeys), len(wantKeys), gotKeys)
		}
		for i := range wantKeys {
			if gotKeys[i] != wantKeys[i] {
				t.Errorf("%s: работа %d — %q, в модели %q", level, i, gotKeys[i], wantKeys[i])
			}
		}
	}
}

// Разделы закрытые: свой раздел, не попавший в Sections(), выпал бы из подсчёта
// процентов молча — работа есть, а в проценте её нет.
func TestSectionsAreFromTheClosedList(t *testing.T) {
	known := make(map[string]bool)
	for _, section := range Sections() {
		known[section] = true
	}

	used := make(map[string]bool)
	for name, tasks := range allTaskLists() {
		for _, task := range tasks {
			if !known[task.Section] {
				t.Errorf("%s: работа %q лежит в разделе %q, которого нет в Sections()",
					name, task.Key, task.Section)
			}
			used[task.Section] = true
		}
	}

	for _, section := range Sections() {
		if !used[section] {
			t.Errorf("раздел %q не используется ни одной работой", section)
		}
	}
}

// Формат меняет ровно три работы и только название с инструкцией: ключ обязан
// остаться прежним, иначе процент по «технике» у офисного и удалённого песка
// считался бы по разным наборам, а отметки разошлись бы при смене формата.
func TestRemoteChangesWordingButNotKeys(t *testing.T) {
	changed := map[string]bool{"hardware": true, "keys": true, "inventory": true}

	for level, lists := range map[string][2][]Task{
		"песок":   {SandboxTasks(Office), SandboxTasks(Remote)},
		"человек": {EmployeeTasks(Office), EmployeeTasks(Remote)},
	} {
		office, remote := lists[0], lists[1]
		if len(office) != len(remote) {
			t.Fatalf("%s: работ в офисе %d, на удалёнке %d — набор обязан быть один",
				level, len(office), len(remote))
		}

		for i := range office {
			if office[i].Key != remote[i].Key {
				t.Errorf("%s: работа %d сменила ключ: %q → %q",
					level, i, office[i].Key, remote[i].Key)
				continue
			}
			if office[i].Section != remote[i].Section {
				t.Errorf("%s: работа %q сменила раздел: %q → %q",
					level, office[i].Key, office[i].Section, remote[i].Section)
			}

			differs := office[i].Title != remote[i].Title || office[i].About != remote[i].About
			if changed[office[i].Key] && !differs {
				t.Errorf("%s: у удалённого песка %q осталась офисная формулировка", level, office[i].Key)
			}
			if !changed[office[i].Key] && differs {
				t.Errorf("%s: формат сменил формулировку у %q, а меняет он только технику и ключи",
					level, office[i].Key)
			}
		}
	}
}

// У не вышедшего исход — комплексное «Увольнение», а не та же работа с другим
// значком: за ней стоит отключение аккаунта, снятие номера и возврат техники.
func TestRejectedOutcomeBecomesDismissal(t *testing.T) {
	going, ok := TaskByKey(EmployeeTasksFor(Office, OutcomeUnknown), "outcome")
	if !ok {
		t.Fatal("работы исхода нет в списке")
	}
	rejected, _ := TaskByKey(EmployeeTasksFor(Office, OutcomeRejected), "outcome")
	hired, _ := TaskByKey(EmployeeTasksFor(Office, OutcomeHired), "outcome")

	if rejected.Title != "Увольнение" {
		t.Errorf("у не вышедшего задача исхода называется %q", rejected.Title)
	}
	if rejected.Key != going.Key {
		t.Errorf("задача исхода сменила ключ: %q вместо %q", rejected.Key, going.Key)
	}
	if hired.Title != going.Title {
		t.Errorf("у вышедшего в ОП формулировка разъехалась с обычной: %q", hired.Title)
	}
	if rejected.About == going.About {
		t.Error("инструкция «Увольнения» не отличается от обычного исхода")
	}
}

// Незаполненная подстановка гасит ссылку, а не отдаёт битую: адрес карточки
// без ID открывает чужой аккаунт, и правят в нём тоже чужого.
func TestLinkWithoutValueIsDark(t *testing.T) {
	card := Link{Title: "Карточка", URL: linkBitrixUser, Needs: PlaceholderBitrix}

	if _, ready := card.For(""); ready {
		t.Error("ссылка с пустым ID показана готовой")
	}
	if _, ready := card.For("   "); ready {
		t.Error("ссылка с пробелами вместо ID показана готовой")
	}

	href, ready := card.For("12817")
	if !ready {
		t.Fatal("ссылка с заполненным ID не собралась")
	}
	if href != linkBitrixUser+"12817" {
		t.Errorf("собралась в %q", href)
	}

	// Адрес без подстановки готов всегда.
	list := Link{Title: "Список", URL: linkBitrixUsers}
	if href, ready := list.For(""); !ready || href != linkBitrixUsers {
		t.Errorf("готовый адрес испорчен: %q (%v)", href, ready)
	}
}

// Ссылки собираются только из шаблона: введённое руками уходит в строку
// запроса, и незакрытое там значение развалило бы адрес молча.
func TestLinkEscapesHandTypedValue(t *testing.T) {
	card := Link{URL: linkBitrixUser, Needs: PlaceholderBitrix}

	href, ready := card.For("12817&role=admin")
	if !ready {
		t.Fatal("ссылка не собралась")
	}
	if strings.Contains(strings.TrimPrefix(href, linkBitrixUser), "&") {
		t.Errorf("в адрес уехал неэкранированный параметр: %q", href)
	}
}

// Процент считается по каждому разделу отдельно: одно число на песок прятало
// бы, что человек заведён, а база ему не налита.
func TestProgressCountsEachSectionApart(t *testing.T) {
	tasks := EmployeeTasks(Office)
	done := map[string]bool{
		"bitrix":      true, // аккаунты: 1 из 1
		"base_filled": true, // база: 1 из 2
	}

	got := make(map[string]SectionProgress)
	for _, section := range Progress(tasks, done) {
		got[section.Section] = section
	}

	if accounts := got[SectionAccounts]; accounts.Percent() != 100 {
		t.Errorf("аккаунты: %d %% (%d из %d)", accounts.Percent(), accounts.Done, accounts.Total)
	}
	if base := got[SectionBase]; base.Done != 1 || base.Total != 2 || base.Percent() != 50 {
		t.Errorf("база: %d из %d, %d %%", base.Done, base.Total, base.Percent())
	}
	if outcome := got[SectionOutcome]; outcome.Done != 0 || outcome.Percent() != 0 {
		t.Errorf("исход: %d из %d", outcome.Done, outcome.Total)
	}
}

// Порядок разделов один и тот же на всех экранах: проценты читают взглядом
// сверху вниз, и переставленные местами строки сравнивать нечем.
func TestProgressKeepsSectionOrder(t *testing.T) {
	tasks := EmployeeTasks(Office)
	order := Progress(tasks, nil)

	at := 0
	for _, section := range Sections() {
		if at < len(order) && order[at].Section == section {
			at++
		}
	}
	if at != len(order) {
		t.Errorf("разделы вышли не в порядке Sections(): %v", order)
	}

	// Раздела без работ в выводе быть не должно: «0 %» там, где делать нечего,
	// читается как невыполненная работа.
	for _, section := range order {
		if section.Total == 0 {
			t.Errorf("раздел %q показан пустым", section.Section)
		}
	}
}

// Пустых работ у песка не бывает: у каждой есть название, раздел и инструкция.
// Задача без инструкции — это строка, о которой спрашивают в чате.
func TestEveryTaskIsFilledIn(t *testing.T) {
	for name, tasks := range allTaskLists() {
		for _, task := range tasks {
			switch {
			case task.Key == "":
				t.Errorf("%s: работа без ключа: %+v", name, task)
			case task.Title == "":
				t.Errorf("%s: %q без названия", name, task.Key)
			case task.About == "":
				t.Errorf("%s: %q без инструкции", name, task.Key)
			}
			for _, link := range task.Links {
				if link.Title == "" || link.URL == "" {
					t.Errorf("%s: у %q ссылка без названия или адреса: %+v", name, task.Key, link)
				}
			}
		}
	}
}

// Справочник РОПов закрыт и не правится вызывающим: свободный текст означал бы
// «Кочура» и «кочура» как два разных песка, а запрет на второй активный песок
// перестал бы работать.
func TestROPDirectoryIsClosed(t *testing.T) {
	want := []string{"Сайдаралиев", "Кочура", "Власов", "Макаренко", "Шахалиева", "Марк", "Скрылева"}
	got := ROPs()

	if len(got) != len(want) {
		t.Fatalf("РОПов %d, ожидалось %d: %v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("РОП %d — %q, ожидался %q", i, got[i], want[i])
		}
	}

	for _, rop := range want {
		if !KnownROP(rop) {
			t.Errorf("%q не признан справочником", rop)
		}
	}
	for _, stranger := range []string{"", "кочура", "Кочура ", "Иванов"} {
		if KnownROP(stranger) {
			t.Errorf("%q принят за РОПа из справочника", stranger)
		}
	}

	// Правка возвращённого среза не должна доходить до справочника.
	ROPs()[0] = "Подменённый"
	if !KnownROP("Сайдаралиев") {
		t.Error("справочник изменился снаружи")
	}
}

// Запрос к Libra подставляет ID и не появляется без него: панель к Libra не
// ходит, а запрос с пустым местом выдал бы доступ не тому.
func TestLibraSQLNeedsBitrixID(t *testing.T) {
	if _, ok := LibraSQL(""); ok {
		t.Error("запрос собрался без ID Битрикса")
	}
	if _, ok := LibraSQL("  "); ok {
		t.Error("запрос собрался из пробелов")
	}
	for _, unsafe := range []string{"12a17", "1); DROP TABLE users;--", "12817 OR 1=1"} {
		if _, ok := LibraSQL(unsafe); ok {
			t.Errorf("запрос собрался из недопустимого ID %q", unsafe)
		}
	}

	query, ok := LibraSQL("12817")
	if !ok {
		t.Fatal("запрос не собрался с заполненным ID")
	}
	if !strings.Contains(query, "(12817)") {
		t.Errorf("ID не подставился: %s", query)
	}
	if !strings.Contains(query, "INSERT INTO [dbo].[ESLibra_UsersAccess]") ||
		!strings.Contains(query, "SELECT * FROM [dbo].[ESLibra_UsersAccess]") {
		t.Errorf("запрос разошёлся с тем, что выполняют руками: %s", query)
	}
}

func keysOf(tasks []Task) []string {
	out := make([]string, 0, len(tasks))
	for _, task := range tasks {
		out = append(out, task.Key)
	}
	return out
}
