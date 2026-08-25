package panel

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/preset"
)

// Приставки помашинных объектов. Те же, что у Worker'а, — worker/worker.js.
const (
	machinePrefix = "machines/"
	accessPrefix  = "access/"
	revokedPrefix = "revoked/"
)

// MachineWriter кладёт в бакет то, что принадлежит одной машине.
//
// Три объекта, и они нарочно разные по назначению:
//
//   - `machines/<id>` — служебная запись, которую читает **только Worker**:
//     хеши ключей доступа. Наружу не раздаётся никогда.
//   - `access/<id>` — то, что забирает сама машина: административный пароль её
//     предустановки. В общий файл предустановок он не едет — файл один на
//     контору, и любой оператор прочитал бы там пароль техподдержки.
//   - `revoked/<id>` — подписанный отзыв. Единственное, что запускает сброс.
//
// Разделение служебного и раздаваемого обязательно: объект, по которому Worker
// проверяет ключ, не может быть тем же, что он по этому ключу отдаёт.
type MachineWriter struct {
	Publisher Publisher

	// SigningKey — тот же ключ линии предустановок. Помашинные объекты
	// подписываются им же: два ключа подписи означали бы два публичных ключа в
	// приложении и второй способ ошибиться, какой из них чей.
	SigningKey ed25519.PrivateKey

	Now func() time.Time
}

// ChannelKeyGrant — один действующий ключ доступа машины.
type ChannelKeyGrant struct {
	Hash     string    `json:"hash"`
	IssuedAt time.Time `json:"issued_at"`
}

// machineRecord — то, что читает Worker.
type machineRecord struct {
	Format         int               `json:"format"`
	InstallationID string            `json:"installation_id"`
	Keys           []ChannelKeyGrant `json:"keys"`
	UpdatedAt      time.Time         `json:"updated_at"`
}

// accessPayload — то, что забирает машина.
type accessPayload struct {
	Format         int       `json:"format"`
	InstallationID string    `json:"installation_id"`
	PresetID       string    `json:"preset_id"`
	AdminPassword  string    `json:"admin_password"`
	IssuedAt       time.Time `json:"issued_at"`
}

// revokedPayload — подписанный отзыв.
type revokedPayload struct {
	Format         int       `json:"format"`
	InstallationID string    `json:"installation_id"`
	RevokedAt      time.Time `json:"revoked_at"`
}

// Keys переписывает перечень действующих ключей машины.
//
// Перечень, а не один ключ: при перепрошивке недолгое время действуют оба.
// Новый кладётся первым, старый гаснет только по отметке о забранном пакете —
// обратный порядок оставлял бы машину без предустановок, упади панель в
// промежутке.
func (m *MachineWriter) Keys(ctx context.Context, installationID string, keys []ChannelKeyGrant) error {
	record := machineRecord{
		Format:         1,
		InstallationID: installationID,
		Keys:           keys,
		UpdatedAt:      m.now().UTC().Truncate(time.Second),
	}
	body, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("собрать запись машины %s: %w", installationID, err)
	}
	if err := m.Publisher.Put(ctx, machinePrefix+installationID, body); err != nil {
		return fmt.Errorf("выложить запись машины %s: %w", installationID, err)
	}
	return nil
}

// Access выкладывает то, что машина забирает по своему ключу.
func (m *MachineWriter) Access(ctx context.Context, installationID, presetID, adminPassword string) error {
	body, err := m.sign(accessPayload{
		Format:         1,
		InstallationID: installationID,
		PresetID:       presetID,
		AdminPassword:  adminPassword,
		IssuedAt:       m.now().UTC().Truncate(time.Second),
	})
	if err != nil {
		return fmt.Errorf("собрать доступ машины %s: %w", installationID, err)
	}
	if err := m.Publisher.Put(ctx, accessPrefix+installationID, body); err != nil {
		return fmt.Errorf("выложить доступ машины %s: %w", installationID, err)
	}
	return nil
}

// Revoke выкладывает подписанный отзыв.
//
// Подписанный, а не просто выложенный: сброс по отсутствию доступа означал бы,
// что опечатка в правиле Cloudflare или оборвавшаяся уборка стирают не одну
// машину, а все тридцать разом. Отсутствие ответа никогда не означает отзыв.
func (m *MachineWriter) Revoke(ctx context.Context, installationID string) error {
	body, err := m.sign(revokedPayload{
		Format:         1,
		InstallationID: installationID,
		RevokedAt:      m.now().UTC().Truncate(time.Second),
	})
	if err != nil {
		return fmt.Errorf("собрать отзыв машины %s: %w", installationID, err)
	}
	if err := m.Publisher.Put(ctx, revokedPrefix+installationID, body); err != nil {
		return fmt.Errorf("выложить отзыв машины %s: %w", installationID, err)
	}
	return nil
}

// sign заворачивает содержимое в тот же конверт, что и файл предустановок:
// подпись считается по байтам payload, и проверять её можно до разбора.
func (m *MachineWriter) sign(payload any) ([]byte, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return preset.SignRaw(body, m.SigningKey)
}

func (m *MachineWriter) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

// Revoker отзывает доступ машины.
//
// Отзыв перестал быть учётной записью и стал техническим действием — это
// главное, что дал помашинный ключ доступа. Делается он в три шага, и порядок
// в них не безразличен:
//
//  1. в базе ставится отметка — она переживёт всё остальное;
//  2. выкладывается подписанный отзыв — по нему машина сбрасывается;
//  3. уносятся machines/<id> и access/<id> — машина перестаёт получать что бы
//     то ни было, а её административный пароль исчезает из бакета.
//
// Третий шаг стоит последним намеренно. Сними доступ первым — и машина уже не
// сможет забрать сам отзыв, то есть не узнает, что её сбросили: останется
// работать со старыми настройками до тех пор, пока на АТС не сменят пароль
// пира. Отзыв, который не доехал, ничем не лучше отсутствующего.
type Revoker struct {
	DB       revokeStore
	Machines *MachineWriter
	Deleter  Deleter
}

// revokeStore — то немногое, что Revoker'у нужно от базы.
type revokeStore interface {
	RevokeActivation(ctx context.Context, actor *int64, id int64) error
	ActivationByID(ctx context.Context, id int64) (model.Activation, error)
}

// Revoke отзывает активацию и обрывает доступ машины к каналу.
func (r *Revoker) Revoke(ctx context.Context, actor *int64, id int64) error {
	found, err := r.DB.ActivationByID(ctx, id)
	if err != nil {
		return err
	}
	if err := r.DB.RevokeActivation(ctx, actor, id); err != nil {
		return err
	}

	// Отзыв выкладывается, даже если машина никогда не заберёт его: пакет мог
	// быть и не забран вовсе, и тогда сбрасывать нечего — но объект стоит
	// сотню байт, а разбираться, был ли забран пакет, значит завести ещё одну
	// развилку там, где она ничего не экономит.
	if err := r.Machines.Revoke(ctx, found.InstallationID); err != nil {
		return fmt.Errorf("активация отозвана в панели, но отзыв не выложен: %w", err)
	}
	if err := r.Deleter.Delete(ctx, machinePrefix+found.InstallationID); err != nil {
		return fmt.Errorf("активация отозвана и отзыв выложен, но доступ не обрублен: %w", err)
	}

	// Объект доступа уносится следом: в нём лежит административный пароль
	// предустановки, и оставлять его в бакете после отзыва незачем. Забрать
	// его отозванной машине уже нечем — ключ канала обрублен строкой выше, —
	// но пароль, который никому не нужен, не должен лежать вовсе.
	if err := r.Deleter.Delete(ctx, accessPrefix+found.InstallationID); err != nil {
		return fmt.Errorf("активация отозвана и доступ обрублен, но пароль остался в бакете: %w", err)
	}
	return nil
}
