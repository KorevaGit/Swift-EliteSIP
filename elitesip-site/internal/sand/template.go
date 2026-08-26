package sand

// Шаблон работ — данные в коде, а не таблица в базе.
//
// Инструкции статичны, ссылки одинаковы для всех песков, истории версий не
// ведём: правка шаблона — правка кода и уезжает вместе с выпуском панели.
// Таблица потребовала бы редактора, версий и ответа на вопрос «по какому
// шаблону идёт этот песок»; всё это заказчиком отклонено.

import (
	"fmt"
	"net/url"
	"strings"
)

// Format — как работает вся группа: в офисе или удалённо.
//
// Задаётся на песок целиком, а не на человека. Значения те же, что в CHECK
// таблицы sandboxes: разойтись коду и базе тут негде.
type Format string

const (
	Office Format = "office"
	Remote Format = "remote"
)

// Outcome — исход сотрудника, их ровно два и они взаимоисключающие. Пустой
// означает, что работа по человеку ещё идёт.
type Outcome string

const (
	OutcomeUnknown  Outcome = ""
	OutcomeHired    Outcome = "hired"
	OutcomeRejected Outcome = "rejected"
)

// Разделы, по которым считается процент.
//
// Общего числа на песок нет намеренно: одно число прячет, что человек заведён,
// но база ему не налита. Названия сразу русские — они же и показываются, а
// вторая таблица переводов была бы вторым местом, где их правят.
const (
	SectionAccounts  = "аккаунты"
	SectionTelephony = "телефония"
	SectionAccess    = "доступы"
	SectionBase      = "база"
	SectionHardware  = "техника"
	SectionOutcome   = "исход"
)

// Sections — порядок разделов на экране. Один на весь раздел, чтобы проценты
// у песка и у сотрудника стояли в одинаковом порядке.
func Sections() []string {
	return []string{
		SectionAccounts, SectionTelephony, SectionAccess,
		SectionBase, SectionHardware, SectionOutcome,
	}
}

// rops — закрытый справочник РОПов.
//
// Свободный текст здесь означал бы «Кочура», «кочура» и «Кочура ' » как три
// разных песка, а запрет «один активный песок на РОПа» перестал бы работать.
var rops = []string{
	"Сайдаралиев", "Кочура", "Власов", "Макаренко", "Шахалиева", "Марк", "Скрылева",
}

// ROPs возвращает справочник копией: общий срез вызывающий отсортировал бы
// или дописал под себя, и справочник перестал бы быть закрытым.
func ROPs() []string {
	return append([]string(nil), rops...)
}

// KnownROP — та же проверка, что и в форме, но на сервере. Форма подсказывает,
// запрещает сервер.
func KnownROP(name string) bool {
	for _, rop := range rops {
		if rop == name {
			return true
		}
	}
	return false
}

// Адреса собраны здесь, а не рассыпаны по задачам: они одни на все пески, и
// переезд АТС или таблицы номеров правится в одном месте.
const (
	linkBitrixUser  = "https://crm.elitesochi.com/bitrix/admin/user_edit.php?lang=ru&ID="
	linkBitrixUsers = "https://crm.elitesochi.com/bitrix/admin/user_admin.php?lang=ru&set_default=Y&apply_filter=Y"
	linkExtension   = "http://192.168.1.2/admin/config.php?display=extensions&extdisplay="
	linkNumbersDoc  = "https://docs.google.com/spreadsheets/d/1jsDjOP2J5mxKgOEVdhFyU7VJW9mZLxe-n2cEH3Ji7ME/edit?pli=1&gid=435847906#gid=435847906"
	linkOBS         = "https://obsproject.com/ru"
	linkAnyDesk     = "https://anydesk.com/ru"
)

// Placeholder — чем достраивается ссылка. Пустой означает, что адрес готов
// целиком.
type Placeholder string

const (
	NoPlaceholder     Placeholder = ""
	PlaceholderBitrix Placeholder = "bitrix_id"
	PlaceholderExt    Placeholder = "extension"
)

// Link — ссылка рядом с задачей.
type Link struct {
	Title string
	URL   string      // адрес целиком либо основа, к которой дописывают значение
	Needs Placeholder // что дописать; пустой — ссылка готова
}

// For достраивает ссылку значением подстановки.
//
// Второе значение — готова ли ссылка. Незаполненную подстановку показываем
// погашенной, а не битой: ссылка на карточку без ID открывает чужой аккаунт,
// и правят в нём тоже чужого.
func (l Link) For(value string) (string, bool) {
	if l.Needs == NoPlaceholder {
		return l.URL, true
	}
	value = strings.TrimSpace(value)
	if value == "" {
		return "", false
	}
	// Значения вводятся руками, поэтому экранируются: адрес дописывается в
	// строку запроса, и лишний & там развалил бы ссылку молча.
	return l.URL + url.QueryEscape(value), true
}

// Task — одна работа шаблона.
type Task struct {
	Key     string   // ключ, он же имя в таблице отметок
	Title   string   // как называется на экране
	Section string   // раздел для процента
	About   string   // инструкция
	Needs   []string // ключи, без которых отметить нельзя
	Links   []Link   // ссылки, часть с подстановкой
}

// SandboxTasks — работы на песок целиком.
//
// Список собирается заново на каждый вызов: общий срез вызывающий дополнил бы
// под свой экран, а шаблон обязан быть одинаковым для всех песков.
func SandboxTasks(format Format) []Task {
	hardware := Task{
		Key:     "hardware",
		Title:   "Выдана техника на песок",
		Section: SectionHardware,
		About: "Ноутбуки, гарнитуры и всё остальное на всю группу разом. " +
			"Склада в панели нет: что именно и кому выдано, знает техподдержка, здесь только отметка.",
	}
	keys := Task{
		Key:     "keys",
		Title:   "Выдан пул ключей",
		Section: SectionHardware,
		About: "Ключи RusGuard на всю группу. Привязка ключа к конкретному человеку — " +
			"отдельная работа в его карточке.",
	}

	// У удалённого песка техника и ключи не выдаются — вместо выдачи удалённая
	// настройка. Ключ остаётся прежним нарочно: иначе процент по разделу
	// «техника» у офисного и удалённого песка считался бы по разным наборам, а
	// отметки разошлись бы при смене формата.
	if format == Remote {
		hardware.Title = "Настроен удалённый доступ"
		hardware.About = "Технику удалёнщикам не возят. Вместо выдачи — настройка на машине сотрудника: " +
			"AnyDesk, через который к ней и подключаются."
		hardware.Links = []Link{{Title: "AnyDesk", URL: linkAnyDesk}}

		keys.Title = "Настроена запись экрана"
		keys.About = "Ключей удалёнщику не выдают — в офис он не заходит. Вместо них ставится OBS."
		keys.Links = []Link{{Title: "OBS", URL: linkOBS}}
	}

	return []Task{
		{
			Key:     "extensions",
			Title:   "Пул внутренних номеров",
			Section: SectionTelephony,
			About: "Номера берутся на всю группу разом и дальше раздаются людям. " +
				"Диапазон вводится как «301-330» — панель его развернёт. Один номер не может " +
				"лежать в двух незакрытых песках сразу.",
			Links: []Link{{Title: "Номера в gdocs", URL: linkNumbersDoc}},
		},
		hardware,
		keys,
		{
			Key:     "libra",
			Title:   "Выдан доступ к Libra",
			Section: SectionAccess,
			About: "Доступ на группу целиком. Запрос по каждому человеку лежит в его карточке: " +
				"панель к Libra не ходит и ходить не будет, запрос выполняет человек.",
		},
		{
			Key:     "seized",
			Title:   "Техника не вышедших изъята",
			Section: SectionHardware,
			Needs:   []string{"hardware"},
			About: "Закрывается, когда собрано у всех, кто не вышел в ОП. Пока техника на песок " +
				"не выдавалась, отметить нельзя — изымать было бы нечего.",
		},
	}
}

// EmployeeTasks — работы по одному сотруднику.
//
// Задача исхода названа для того, у кого он ещё не наступил. Когда исход
// известен, берут EmployeeTasksFor: у не вышедшего это другая работа, а не
// та же с другим значком.
func EmployeeTasks(format Format) []Task {
	return EmployeeTasksFor(format, OutcomeUnknown)
}

// EmployeeTasksFor — тот же список, но задача исхода названа по факту.
func EmployeeTasksFor(format Format, outcome Outcome) []Task {
	inventory := Task{
		Key:     "inventory",
		Title:   "Проинвентаризирована техника",
		Section: SectionHardware,
		About: "Что у человека на руках — записывается за ним. Склада в панели нет: " +
			"это отметка о том, что сверка проведена.",
	}
	if format == Remote {
		inventory.Title = "Проверена удалённая настройка"
		inventory.About = "Сверять на руках нечего — техника осталась своя. Проверяется то, что " +
			"настраивали: подключение через AnyDesk и запись экрана."
		inventory.Links = []Link{
			{Title: "AnyDesk", URL: linkAnyDesk},
			{Title: "OBS", URL: linkOBS},
		}
	}

	// Исход у не вышедшего — одна осознанно комплексная работа, а не россыпь
	// флажков: отключение аккаунта, снятие номера, изъятие техники и остальные
	// доступы закрываются вместе или не закрываются вовсе.
	result := Task{
		Key:     "outcome",
		Title:   "Выведен в ОП",
		Section: SectionOutcome,
		Needs:   []string{"bitrix"},
		About: "Исход ровно один из двух: принят менеджером или уволен. Ставится вместе с самим " +
			"исходом одной транзакцией — отдельным флажком он не переключается.",
	}
	if outcome == OutcomeRejected {
		result.Title = "Увольнение"
		result.About = "Одна комплексная задача, а не россыпь флажков: отключён аккаунт Битрикса, " +
			"снят внутренний номер, изъята техника и закрыты остальные доступы. Отмечается только " +
			"после всего комплекса."
	}

	return []Task{
		{
			Key:     "bitrix",
			Title:   "Создан аккаунт в Битриксе",
			Section: SectionAccounts,
			About: "Логин, пароль и ID вводятся руками — панель в Битрикс не ходит. Пока ID пуст, " +
				"не работают ни запрос к Libra, ни выдача сделок: подставлять в них нечего.",
			Links: []Link{
				{Title: "Список пользователей", URL: linkBitrixUsers},
				{Title: "Карточка в Битриксе", URL: linkBitrixUser, Needs: PlaceholderBitrix},
			},
		},
		{
			Key:     "libra",
			Title:   "Выдан доступ к Libra",
			Section: SectionAccess,
			Needs:   []string{"bitrix"},
			About: "Рядом с задачей лежит готовый запрос с подставленным ID Битрикса. Выполняет его " +
				"человек: панель к Libra не подключается и подключаться не будет.",
		},
		{
			Key:     "extension",
			Title:   "Привязан внутренний номер",
			Section: SectionTelephony,
			Needs:   []string{"bitrix"},
			About: "Номер из пула песка, и он же прописывается в трёх местах: Битрикс, PBX и gdocs. " +
				"Разойтись они не должны — звонить будет не тому.",
			Links: []Link{
				{Title: "Правка номера на АТС", URL: linkExtension, Needs: PlaceholderExt},
				{Title: "Номера в gdocs", URL: linkNumbersDoc},
			},
		},
		{
			Key:     "base_filled",
			Title:   "Налита холодная база",
			Section: SectionBase,
			Needs:   []string{"bitrix"},
			About: "Кнопки 300 и 100 отдают CSV порции. Пока порция не отмечена налитой, повторное " +
				"нажатие отдаёт тот же файл, а не следующие сделки.",
		},
		inventory,
		result,
		{
			Key:     "base_drained",
			Title:   "Слил холодную базу",
			Section: SectionBase,
			Needs:   []string{"base_filled"},
			About:   "Выданные сделки отработаны. Пока база не наливалась, сливать нечего.",
		},
		{
			Key:     "rusguard",
			Title:   "Привязан ключ RusGuard",
			Section: SectionAccess,
			About:   "Ключ из выданного на песок пула закрепляется за человеком.",
		},
	}
}

// TaskByKey ищет работу в списке.
func TaskByKey(tasks []Task, key string) (Task, bool) {
	for _, task := range tasks {
		if task.Key == key {
			return task, true
		}
	}
	return Task{}, false
}

// SectionProgress — сколько работ раздела закрыто.
type SectionProgress struct {
	Section string
	Done    int
	Total   int
}

// Percent — метод, а не поле: посчитанное рядом с исходными числами разошлось
// бы с ними при первой же правке одного из трёх.
func (p SectionProgress) Percent() int {
	if p.Total == 0 {
		return 0
	}
	return p.Done * 100 / p.Total
}

// Progress считает процент по каждому разделу отдельно.
//
// Берёт и список работ, и отметки: набор работ зависит от формата песка, и
// считать проценты по чужому набору — это показать 100 % там, где половину
// задач просто не показали.
func Progress(tasks []Task, done map[string]bool) []SectionProgress {
	out := make([]SectionProgress, 0, len(Sections()))
	for _, section := range Sections() {
		var counted SectionProgress
		counted.Section = section
		for _, task := range tasks {
			if task.Section != section {
				continue
			}
			counted.Total++
			if done[task.Key] {
				counted.Done++
			}
		}
		// Раздел без работ не показываем вовсе: «0 %» там, где делать нечего,
		// читается как невыполненная работа.
		if counted.Total > 0 {
			out = append(out, counted)
		}
	}
	return out
}

// LibraSQL — запрос, который техподдержка копирует и выполняет руками.
//
// Второе значение — есть ли что копировать. Панель к Libra не ходит: она
// избавляет от ручной подстановки числа, и только. Пока ID Битрикса не введён,
// кнопки копирования нет — запрос с пустым местом выдал бы доступ не тому.
func LibraSQL(bitrixID string) (string, bool) {
	bitrixID = strings.TrimSpace(bitrixID)
	if bitrixID == "" || !onlyDigits(bitrixID) {
		return "", false
	}
	return fmt.Sprintf(`INSERT INTO [dbo].[ESLibra_UsersAccess]
([USER_ID])
VALUES
(%s)

SELECT * FROM [dbo].[ESLibra_UsersAccess]`, bitrixID), true
}
