// Package panel — действия панели, которые не сводятся к одной таблице.
package panel

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/activation"
	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/storage"
)

// KeyLifetime — сколько живёт выпущенный ключ.
//
// Двое суток: столько занимает «выдали и человек сел настраиваться». Срок узко
// ограничивает окно, в котором перехваченный ключ ещё чего-то стоит, — а стоит
// он рабочего места целиком.
const KeyLifetime = 48 * time.Hour

// Publisher кладёт пакет активации туда, откуда его заберёт машина.
//
// Интерфейс, а не сразу R2: панель стоит внутри сети и наружу только пишет,
// поэтому подменить хранилище на локальный каталог для проверки должно быть
// можно, не трогая выпуск.
type Publisher interface {
	Put(ctx context.Context, objectKey string, data []byte) error
}

// Issuer выпускает ключи активации.
type Issuer struct {
	DB        *storage.DB
	Publisher Publisher

	// Secret — секрет сервера для отпечатков ключей. Лежит файлом рядом с
	// базой, а не в ней: иначе бэкап базы становился бы ещё и связкой ключей.
	Secret []byte

	// Now подменяется в проверках. В бою — time.Now.
	Now func() time.Time
}

// Issue выпускает ключ для сотрудника.
//
// Ключ возвращается ровно один раз и больше не восстанавливается ниоткуда: он
// же служит ключом расшифровки пакета, и хранить его значило бы держать замок
// вместе с ключом. Потерялся — выпускается новый.
func (i *Issuer) Issue(ctx context.Context, actor *int64, employeeID int64, note string) (activation.Key, model.Activation, error) {
	now := i.now()

	subject, err := i.DB.SubjectForIssue(ctx, employeeID)
	if err != nil {
		return "", model.Activation{}, err
	}

	revision, err := i.DB.RevisionByID(ctx, subject.RevisionID)
	if err != nil {
		return "", model.Activation{}, err
	}

	adminPassword, err := i.DB.Setting(ctx, storage.SettingAdminPassword)
	if err != nil {
		return "", model.Activation{}, err
	}
	if adminPassword == "" {
		// Без него машина активируется, но «Управление» на ней потом не
		// откроется ничем: пароль перестал быть вшитым в сборку ровно затем,
		// чтобы приезжать отсюда.
		return "", model.Activation{}, fmt.Errorf(
			"административный пароль конторы не задан — задайте его в настройках панели")
	}

	key, err := activation.New()
	if err != nil {
		return "", model.Activation{}, err
	}
	installationID, err := activation.NewInstallationID()
	if err != nil {
		return "", model.Activation{}, err
	}

	payload := activation.Payload{
		Format:         activation.PayloadFormat,
		InstallationID: installationID,
		IssuedAt:       now.UTC().Truncate(time.Second),
		Employee:       subject.EmployeeName,
		Number:         subject.Number,
		SIPPassword:    subject.SIPPassword,
		AdminPassword:  adminPassword,
		Preset: activation.PresetPayload{
			ID:            subject.PresetPublicID,
			Name:          subject.PresetName,
			Revision:      revision.Revision,
			SchemaVersion: revision.SchemaVersion,
			Settings:      revision.Payload,
		},
	}
	plaintext, err := json.Marshal(payload)
	if err != nil {
		return "", model.Activation{}, fmt.Errorf("собрать пакет активации: %w", err)
	}

	sealed, err := activation.Seal(key, plaintext)
	if err != nil {
		return "", model.Activation{}, err
	}

	// Пакет выкладывается до записи в базу, а не после.
	//
	// Порядок важен, потому что падать может любой из двух шагов. Осиротевший
	// пакет без записи безвреден: ключ от него никому не выдан, и через двое
	// суток он всё равно подлежит уборке. А запись без пакета — это выданный
	// ключ, который не работает, и сотрудник, звонящий в поддержку из дома.
	if err := i.Publisher.Put(ctx, key.ObjectKey(), sealed); err != nil {
		return "", model.Activation{}, fmt.Errorf("выложить пакет активации: %w", err)
	}

	saved, err := i.DB.SaveActivation(ctx, actor, storage.IssueRecord{
		EmployeeID:     subject.EmployeeID,
		PresetID:       subject.PresetID,
		KeyFingerprint: activation.Fingerprint(i.Secret, key),
		KeyPrefix:      key.Prefix(),
		ObjectKey:      key.ObjectKey(),
		InstallationID: installationID,
		ExpiresAt:      now.Add(KeyLifetime),
		Note:           note,
	})
	if err != nil {
		return "", model.Activation{}, err
	}
	return key, saved, nil
}

func (i *Issuer) now() time.Time {
	if i.Now != nil {
		return i.Now()
	}
	return time.Now()
}
