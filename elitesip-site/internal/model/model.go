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

// Number — добавочный на АТС.
//
// Сущность отдельная от сотрудника, потому что переживает его: номер отдают
// новому человеку, и вопрос «кто сидел на 172 в марте» должен иметь ответ.
type Number struct {
	ID          int64
	Number      string
	SIPPassword string
	Label       string
	CreatedAt   time.Time
	RetiredAt   *time.Time
}

// Employee — сотрудник. Единица учёта: ключи выписываются на человека.
type Employee struct {
	ID          int64
	Name        string
	PresetID    *int64
	CreatedAt   time.Time
	DismissedAt *time.Time
}

// Assignment — за кем закреплён номер и когда.
//
// Действующее назначение — то, у которого ReleasedAt пуст. База следит, чтобы
// такое было не больше одного на номер и не больше одного на сотрудника.
type Assignment struct {
	ID         int64
	NumberID   int64
	EmployeeID int64
	AssignedAt time.Time
	ReleasedAt *time.Time
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
type Activation struct {
	ID             int64
	EmployeeID     int64
	PresetID       int64
	KeyFingerprint string
	KeyPrefix      string
	ObjectKey      string
	InstallationID string
	IssuedBy       *int64
	IssuedAt       time.Time
	ExpiresAt      time.Time
	FetchedAt      *time.Time
	RevokedAt      *time.Time
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
	// Учётная запись факта, а не техническое действие: приложение после
	// активации к панели не ходит. Машину останавливает смена SIP-пароля пира
	// на АТС — см. DECISIONS.md, «Отзыв доступа».
	ActivationRevoked ActivationState = "отозвано"
)

// State определяет состояние на заданный момент.
//
// Отзыв важнее срока: отозванное вчера и просроченное сегодня — это отозванное,
// иначе в списке пропала бы разница между «выгнали» и «не дошли руки».
func (a Activation) State(now time.Time) ActivationState {
	switch {
	case a.RevokedAt != nil:
		return ActivationRevoked
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
