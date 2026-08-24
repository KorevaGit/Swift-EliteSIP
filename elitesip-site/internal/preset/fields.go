// Package preset — управляемые поля предустановки: что панель редактирует и
// что уезжает в файл на R2.
//
// Это контракт с приложением, и он умышленно повторяет Codable-представление
// соответствующих типов Swift: `dtmf` — это `AppSettings.DTMFSettings`,
// `incomingCall` — `CallGuardPolicy`, и так далее. Свой формат был бы честнее
// в том смысле, что не притворялся бы куском чужой модели, но потребовал бы на
// клиенте слоя перекладывания — а слой, который перекладывает поля руками,
// однажды переложит не то.
//
// Границу «что панель, а что машина» задаёт docs/DECISIONS.md. Здесь её видно
// по составу: звука, рингтона, оформления, журналов и истории тут нет.
package preset

import (
	"encoding/json"
	"fmt"
	"strings"
)

// SchemaVersion — версия схемы AppSettings, под которую собран этот набор.
//
// Совпадает с AppSettings.currentSchemaVersion в приложении. Машина со старой
// сборкой применит понятное и пропустит остальное, а панель покажет, что она
// отстала.
const SchemaVersion = 2

// Fields — управляемые поля целиком.
//
// Каждое поле необязательно, и пустое означает «панель этим не управляет»:
// машина сохраняет своё текущее значение, а не сбрасывает его в умолчание. Это
// правило принято ещё в M8 и здесь только соблюдается — иначе предустановка,
// написанная ради макросов, молча стирала бы политику защиты.
type Fields struct {
	DTMF         *DTMF          `json:"dtmf,omitempty"`
	IncomingCall *CallGuard     `json:"incomingCall,omitempty"`
	Queues       *Queues        `json:"queues,omitempty"`
	Conference   *Conference    `json:"conference,omitempty"`
	PortKnock    *PortKnock     `json:"portKnock,omitempty"`
	SiteAddress  *SiteAddresses `json:"siteAddresses,omitempty"`

	// AcceptsAnyTLSCertificate живёт в приложении внутри активного профиля, а
	// не в AppSettings, поэтому здесь оно отдельным полем верхнего уровня.
	//
	// Управляется панелью ровно затем, чтобы держать его выключенным: аудит
	// M7b нашёл включённое ради лаборатории значение, молча оставшееся
	// включённым на боевом профиле.
	AcceptsAnyTLSCertificate *bool `json:"acceptsAnyTLSCertificate,omitempty"`
}

// DTMF — тоны и клавиши вместе с их раскладкой.
//
// Раскладка входит сюда, а не в личные настройки, по решению этапа «Интерфейс»:
// кнопка перевода, уехавшая на другое место, — это набранный не тот код, и
// разбирать такой звонок будет уже не тот, кто её двигал.
type DTMF struct {
	ToneMilliseconds  int     `json:"toneMilliseconds"`
	GapMilliseconds   int     `json:"gapMilliseconds"`
	PauseMilliseconds int     `json:"pauseMilliseconds"`
	Macros            []Macro `json:"macros"`

	MacroColumns        int  `json:"macroColumns"`
	MacroHeight         int  `json:"macroHeight"`
	MacroHeightIsManual bool `json:"macroHeightIsManual"`
}

// Macro — одна клавиша панели.
type Macro struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Sequence string `json:"sequence"`

	// TransfersCall помечает, уводит ли клавиша звонок другому человеку.
	//
	// Отвечает администратор, а не догадка по коду: `*02` — это Attended
	// Transfer конкретно боевого сервера, а не общее правило Asterisk. Пометка
	// уходит в историю звонков, которую читают как свидетельство при разборе
	// жалобы, поэтому угадывать её нельзя.
	TransfersCall bool `json:"transfersCall"`
}

// CallGuard — политика защиты приёма вызова.
//
// Поля isServerManaged здесь нет намеренно, хотя в Swift оно есть: им
// приложение помечает «значением управляет сервер, локально только чтение», а
// это теперь выводится из режима машины — «Предустановка» или «Вручную», — а
// не приезжает полем. Приехавшее поле означало бы два источника одного факта.
type CallGuard struct {
	IsEnabled bool `json:"isEnabled"`

	IsRandomPositionEnabled bool    `json:"isRandomPositionEnabled"`
	TunesRandomnessByHand   bool    `json:"tunesRandomnessByHand"`
	MinimumTravel           float64 `json:"minimumTravel"`
	ScreenMargin            float64 `json:"screenMargin"`

	TargetCount int `json:"targetCount"`

	RequiresCursorMovement bool    `json:"requiresCursorMovement"`
	TunesLivenessByHand    bool    `json:"tunesLivenessByHand"`
	RequiredCursorTravel   float64 `json:"requiredCursorTravel"`
	RequiredCursorSamples  int     `json:"requiredCursorSamples"`

	RejectsSyntheticEvents bool `json:"rejectsSyntheticEvents"`
}

// Queues — словарь очередей: по какому номеру приходит раздача и как её
// называть оператору.
type Queues struct {
	Queues []Queue `json:"queues"`
}

// Queue — одна очередь.
type Queue struct {
	ID     string `json:"id"`
	Number string `json:"number"`
	Title  string `json:"title"`
}

// Conference — код конференции и добавочный комнаты.
type Conference struct {
	FeatureCode   string `json:"featureCode"`
	RoomExtension string `json:"roomExtension"`
}

// SiteAddresses — пара адресов одной АТС: изнутри и снаружи.
//
// Меняется раз в несколько лет и ломает связь, если разъедется, — самое
// опасное, что эта линия возит.
type SiteAddresses struct {
	Office string `json:"office"`
	Remote string `json:"remote"`
}

// PortKnock — последовательность стука.
//
// Живёт на чужом шлюзе и может измениться без нас — потому и правится отсюда,
// а не пересборкой приложения.
type PortKnock struct {
	Steps                 []KnockStep `json:"steps"`
	SpacingSeconds        float64     `json:"spacingSeconds"`
	RepeatIntervalSeconds float64     `json:"repeatIntervalSeconds"`
}

// KnockStep — один шаг стука. Пустой Host означает «основной адрес».
type KnockStep struct {
	Host         string `json:"host,omitempty"`
	PayloadBytes int    `json:"payloadBytes"`
	Count        int    `json:"count"`
}

// Canonical сериализует поля для файла и для подписи.
//
// Отступов нет: подписывается ровно то, что уезжает, и лишний пробел означал бы
// другую подпись.
func (f Fields) Canonical() ([]byte, error) {
	data, err := json.Marshal(f)
	if err != nil {
		return nil, fmt.Errorf("собрать поля предустановки: %w", err)
	}
	return data, nil
}

// Parse разбирает поля из JSON строго: незнакомый ключ — ошибка.
//
// Строго именно здесь и именно на входе в панель. У машины правило обратное —
// она пропускает незнакомое и применяет понятное, потому что обязана работать
// со старой сборкой. А панель — то место, где опечатку в имени поля ещё можно
// показать человеку, вместо того чтобы разослать её на все машины.
func Parse(data []byte) (Fields, error) {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()

	var f Fields
	if err := decoder.Decode(&f); err != nil {
		return Fields{}, fmt.Errorf("разобрать поля предустановки: %w", err)
	}
	return f, nil
}
