// Package model — сущности панели.
//
// Раскладка выведена в docs/DECISIONS.md, раздел «Модель данных». Здесь только
// то, что не видно из имён полей.
package model

import (
	"encoding/json"
	"time"
)

// Admin — администратор панели. Ролей нет: все могут всё, и потому каждое
// действие пишется в журнал.
type Admin struct {
	ID           int64
	Login        string
	PasswordHash string
	CreatedAt    time.Time
	DisabledAt   *time.Time
}

// Active говорит, пускают ли этого администратора сегодня.
func (a Admin) Active() bool { return a.DisabledAt == nil }

// Employee — сотрудник. Единица учёта, и единственная: ключи выписываются на
// человека, номер и SIP-пароль — его поля.
//
// Отдельной сущностью номер был до разбора 24 августа 2026; отменён вместе с
// увольнением — см. schema.sql и docs/UI.md.
type Employee struct {
	ID   int64
	Name string

	// Пустыми бывают: человека заводят и до того, как на АТС подняли пир.
	Number      string
	SIPPassword string

	PresetID  *int64
	CreatedAt time.Time
}

// Preset — предустановка: имя, под которым живёт череда ревизий.
type Preset struct {
	ID int64

	// PublicID — имя предустановки снаружи: в пакете активации и в файле на R2.
	// Машина ищет по нему, потому что видимое имя переименовывают.
	PublicID string

	Name       string
	CreatedAt  time.Time
	ArchivedAt *time.Time
}

// PresetRevision — одна правка предустановки.
//
// Payload — JSON управляемых полей, ровно тот, что уедет в файл на R2. Он не
// разбирается на столбцы намеренно: модель настроек живёт в Swift, и вторая её
// копия здесь разошлась бы с оригиналом на первой же новой настройке.
type PresetRevision struct {
	ID            int64
	PresetID      int64
	Revision      int
	SchemaVersion int
	Payload       json.RawMessage
	Note          string
	AuthorID      *int64
	CreatedAt     time.Time
	PublishedAt   *time.Time
}

// Published говорит, уехала ли ревизия наружу. Между сохранением на сайте и
// появлением файла в R2 проходит выкладка, и разница видна в интерфейсе.
func (r PresetRevision) Published() bool { return r.PublishedAt != nil }

// Activation — рабочее место сотрудника.
//
// Самого ключа здесь нет: он служит и ключом расшифровки пакета, и потому
// хранился бы рядом с адресом шифротекста. Показать выданный ключ второй раз
// нельзя — выпускается новый.
// ActivationKind — что за ключ выпущен.
type ActivationKind string

const (
	// KindActivation — ключ для чистой машины. Ни к чему не привязан:
	// installation_id рождается в панели и приезжает в пакете.
	KindActivation ActivationKind = "activation"

	// KindReflash — ключ перепрошивки работающей машины. Привязан к её
	// installation_id, который входит в вывод адреса пакета, поэтому не та
	// машина считает другой адрес и пакета не находит вовсе.
	//
	// Без привязки поле ввода ключа в «Техподдержке» позволяло бы любому
	// сотруднику поднять своё место под чужим номером: ключ, улетевший в общий
	// чат отдела, срабатывал бы у кого угодно.
	KindReflash ActivationKind = "reflash"
)

type Activation struct {
	ID             int64
	EmployeeID     int64
	PresetID       int64
	Kind           ActivationKind
	KeyFingerprint string
	KeyPrefix      string
	ObjectKey      string
	InstallationID string
	ChannelKeyHash string
	IssuedBy       *int64
	IssuedAt       time.Time
	ExpiresAt      time.Time
	FetchedAt      *time.Time
	RevokedAt      *time.Time
	SupersededAt   *time.Time
	Note           string
}

// ActivationState — в каком состоянии рабочее место.
type ActivationState string

const (
	// ActivationPending — ключ выдан, пакет ещё не забран.
	ActivationPending ActivationState = "ожидает"
	// ActivationDone — пакет забран, машина настроена.
	ActivationDone ActivationState = "активировано"
	// ActivationExpired — срок вышел, пакета никто не забрал.
	ActivationExpired ActivationState = "просрочено"
	// ActivationRevoked — отозвано администратором.
	//
	// С 25 августа 2026 это техническое действие, а не только запись: панель
	// выкладывает подписанный отзыв, машина забирает его при проверке раз в
	// пятнадцать минут и сбрасывается. Смена SIP-пароля пира на АТС осталась
	// окончательной мерой — отзыв работает, пока машина ходит в сеть.
	ActivationRevoked ActivationState = "отозвано"

	// ActivationSuperseded — ключ вытеснен новым.
	//
	// Случается, когда у сотрудника выпускают четвёртый невостребованный ключ:
	// живёт не больше трёх, старейший гасится.
	ActivationSuperseded ActivationState = "вытеснен"

	// ActivationReflashed — машина перепрошита.
	//
	// Та же погашенная строка, но забранная: рабочее место переехало на другую
	// предустановку по ключу перепрошивки, и вот эта строка — его прошлая
	// жизнь. Отличается от «вытеснен» тем, что за ней стояла настоящая машина.
	ActivationReflashed ActivationState = "перепрошита"
)

// State определяет состояние на заданный момент.
//
// Отзыв важнее срока: отозванное вчера и просроченное сегодня — это отозванное,
// иначе в списке пропала бы разница между «выгнали» и «не дошли руки».
//
// Гашение важнее срока по той же причине и стоит сразу за отзывом: вытесненный
// ключ мог заодно и протухнуть, но администратору важно, что его вытеснили — то
// есть что где-то есть ключ посвежее.
func (a Activation) State(now time.Time) ActivationState {
	switch {
	case a.RevokedAt != nil:
		return ActivationRevoked
	case a.SupersededAt != nil && a.FetchedAt != nil:
		return ActivationReflashed
	case a.SupersededAt != nil:
		return ActivationSuperseded
	case a.FetchedAt != nil:
		return ActivationDone
	case now.After(a.ExpiresAt):
		return ActivationExpired
	default:
		return ActivationPending
	}
}

// Checkin — всё, что панель знает о живом рабочем месте.
//
// Приходит из журнала Worker'а, раздающего файл предустановок, а не от
// приложения: прямого канала от него к панели нет.
type Checkin struct {
	InstallationID string
	LastSeenAt     time.Time
	AppVersion     string
	SchemaVersion  *int
	PresetRevision *int
}

// AuditEntry — строка журнала действий.
type AuditEntry struct {
	ID       int64
	At       time.Time
	AdminID  *int64
	Action   string
	Entity   string
	EntityID *int64
	Details  string
}

// SilenceThreshold — сколько молчания считать поводом подсветить машину.
//
// Пять суток. При двухчасовом опросе это шестьдесят пропущенных заходов: не
// сбой сети и не выходные, а повод выяснять. Меньший срок дал бы ложную тревогу
// пачками — отпуск, командировка, забытый дома ноутбук.
//
// Молчание — единственный признак, по которому панель узнаёт о физическом
// сбросе: он уносит installation_id, канала от машины к панели нет, и в базе
// остаётся строка «активировано» у места, которого больше не существует.
const SilenceThreshold = 5 * 24 * time.Hour

// Silent — машина не выходила на связь дольше срока.
func (c Checkin) Silent(now time.Time) bool {
	return now.Sub(c.LastSeenAt) > SilenceThreshold
}
