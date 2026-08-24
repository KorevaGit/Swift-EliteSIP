package activation

import (
	"encoding/json"
	"time"
)

// PayloadFormat — версия содержимого пакета.
//
// Отдельно от версии формата шифрования (magic): распечатать пакет и не понять
// его содержимое — разные беды с разными сообщениями.
const PayloadFormat = 1

// Payload — то, что лежит внутри пакета активации.
//
// Это контракт между панелью и приложением, и менять его без причины нельзя:
// на другой стороне его читает Swift, который обновляется не одновременно.
// Имена полей — как в файле, змеиным регистром, чтобы обе стороны читались
// одинаково.
type Payload struct {
	Format int `json:"format"`

	// InstallationID — идентификатор машины. С этого момента приложение
	// сообщает его при каждом запросе за файлом предустановок; это
	// единственное, по чему панель вообще узнаёт рабочие места.
	InstallationID string `json:"installation_id"`

	IssuedAt time.Time `json:"issued_at"`

	// Employee — имя сотрудника. Едет не ради красоты: приложение показывает
	// его на экране активации, и человек видит, чьё рабочее место поднимает,
	// до того, как оно зарегистрируется на АТС под чужим номером.
	Employee string `json:"employee"`

	Number      string `json:"number"`
	SIPPassword string `json:"sip_password"`

	// AdminPassword — административный пароль конторы, общий на все машины.
	// Едет отдельным полем, а не внутри предустановки: SettingsPreset вычищает
	// блок доступа намеренно, и ломать это ради одного поля нельзя.
	AdminPassword string `json:"admin_password"`

	Preset PresetPayload `json:"preset"`
}

// PresetPayload — предустановка в том виде, в каком её получает машина.
type PresetPayload struct {
	// ID — по нему машина находит свою предустановку в файле на R2. Не имя:
	// имя переименовывают, и все машины разом перестали бы себя находить.
	ID string `json:"id"`

	Name     string `json:"name"`
	Revision int    `json:"revision"`

	// SchemaVersion — версия схемы AppSettings, под которую собраны настройки.
	// Машина со старой сборкой применит понятное и пропустит остальное.
	SchemaVersion int `json:"schema_version"`

	Settings json.RawMessage `json:"settings"`
}
