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

// MaxPendingKeys — сколько невостребованных ключей живёт у сотрудника.
//
// Четвёртый вытесняет старейший. Считаются именно невостребованные: забранная
// активация — это не ключ, а рабочее место, и её строка держит на себе
// привязку машины к сотруднику. У сотрудника с четырьмя ключами работающая
// машина стоит, как правило, на самом старом из них — на том, который сработал.
const MaxPendingKeys = 3

// Issuer выпускает ключи активации.
type Issuer struct {
	DB        *storage.DB
	Publisher Publisher

	// Machines кладёт помашинные объекты: перечень действующих ключей доступа
	// для Worker'а и административный пароль для самой машины.
	Machines *MachineWriter

	// Bin уносит из бакета пакет, который перестал быть верным.
	//
	// Отдельным полем от Publisher'а и по тому же правилу, по которому Deleter
	// вообще отделён: выпуск обязан уметь класть. Но гашение невостребованного
	// ключа — это тот же выпуск, только наоборот, и делать его из другого места
	// значило бы развести по двум файлам одно решение о том, что такое живой
	// ключ. См. StalePending.
	Bin Deleter

	// Secret — секрет сервера для отпечатков ключей. Лежит файлом рядом с
	// базой, а не в ней: иначе бэкап базы становился бы ещё и связкой ключей.
	Secret []byte

	// Now подменяется в проверках. В бою — time.Now.
	Now func() time.Time
}

// Issue выпускает ключ активации для сотрудника.
//
// Ключ возвращается ровно один раз и больше не восстанавливается ниоткуда: он
// же служит ключом расшифровки пакета, и хранить его значило бы держать замок
// вместе с ключом. Потерялся — выпускается новый.
func (i *Issuer) Issue(ctx context.Context, actor *int64, employeeID int64, note string) (activation.Key, model.Activation, error) {
	subject, err := i.DB.SubjectForIssue(ctx, employeeID)
	if err != nil {
		return "", model.Activation{}, err
	}

	installationID, err := activation.NewInstallationID()
	if err != nil {
		return "", model.Activation{}, err
	}
	subject.InstallationID = installationID

	return i.issue(ctx, actor, subject, model.KindActivation, note)
}

// Reflash выпускает ключ перепрошивки для работающей машины.
//
// Живёт затем, что сотрудник меняет отдел, а ехать к машине ради новой
// предустановки незачем. Ключ привязан к машине: её installation_id входит в
// вывод адреса пакета, поэтому введённый не там он уходит по другому адресу и
// не находит ничего — вместо того чтобы скачаться и сгореть на проверке.
//
// Машина сохраняет свой installation_id. Меняются предустановка, номер,
// SIP-пароль, административный пароль и ключ канала.
func (i *Issuer) Reflash(ctx context.Context, actor *int64, installationID, note string) (activation.Key, model.Activation, error) {
	machine, err := i.DB.LiveActivationByInstallation(ctx, installationID)
	if err != nil {
		return "", model.Activation{}, err
	}
	if machine.FetchedAt == nil {
		// Перепрошивать нечего: пакет ещё не забирали, и сотруднику проще
		// ввести уже выданный ключ, чем получать второй.
		return "", model.Activation{}, fmt.Errorf(
			"эта машина ещё не активирована — у неё есть невостребованный ключ")
	}

	subject, err := i.DB.SubjectForIssue(ctx, machine.EmployeeID)
	if err != nil {
		return "", model.Activation{}, err
	}
	subject.InstallationID = installationID

	return i.issue(ctx, actor, subject, model.KindReflash, note)
}

// issue — общая часть обоих выпусков.
func (i *Issuer) issue(
	ctx context.Context,
	actor *int64,
	subject storage.IssueSubject,
	kind model.ActivationKind,
	note string,
) (activation.Key, model.Activation, error) {
	now := i.now()

	revision, err := i.DB.RevisionByID(ctx, subject.RevisionID)
	if err != nil {
		return "", model.Activation{}, err
	}

	if subject.AdminPassword == "" {
		// Без него машина активируется, но «Управление» на ней потом не
		// откроется ничем: пароль перестал быть вшитым в сборку ровно затем,
		// чтобы приезжать отсюда.
		return "", model.Activation{}, fmt.Errorf(
			"у предустановки «%s» не задан административный пароль", subject.PresetName)
	}

	key, err := activation.New()
	if err != nil {
		return "", model.Activation{}, err
	}
	channelKey, err := activation.NewChannelKey()
	if err != nil {
		return "", model.Activation{}, err
	}

	// Привязка есть только у перепрошивки. У ключа активации машины ещё нет, и
	// в соль подставляется пустая строка.
	var binding activation.Binding
	if kind == model.KindReflash {
		binding = activation.Binding(subject.InstallationID)
	}
	bound, err := activation.Bind(key, binding)
	if err != nil {
		return "", model.Activation{}, err
	}

	payload := activation.Payload{
		Format:         activation.PayloadFormat,
		InstallationID: subject.InstallationID,
		ChannelKey:     channelKey,
		IssuedAt:       now.UTC().Truncate(time.Second),
		Employee:       subject.EmployeeName,
		Number:         subject.Number,
		SIPPassword:    subject.SIPPassword,
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

	sealed, err := bound.Seal(plaintext)
	if err != nil {
		return "", model.Activation{}, err
	}

	// Пакет выкладывается до записи в базу, а не после.
	//
	// Порядок важен, потому что падать может любой из двух шагов. Осиротевший
	// пакет без записи безвреден: ключ от него никому не выдан, и через двое
	// суток он всё равно подлежит уборке. А запись без пакета — это выданный
	// ключ, который не работает, и сотрудник, звонящий в поддержку из дома.
	if err := i.Publisher.Put(ctx, bound.ObjectKey(), sealed); err != nil {
		return "", model.Activation{}, fmt.Errorf("выложить пакет активации: %w", err)
	}

	// Ключ канала кладётся тоже до записи и **добавляется** к прежним, а не
	// заменяет их. При перепрошивке недолгое время действуют оба: старый ещё
	// нужен машине, которая пакет пока не забрала. Гаснет он по отметке о
	// забранном пакете — обратный порядок оставлял бы машину без предустановок,
	// упади панель в промежутке.
	if err := i.grantChannelKey(ctx, subject, channelKey); err != nil {
		return "", model.Activation{}, err
	}

	saved, err := i.DB.SaveActivation(ctx, actor, storage.IssueRecord{
		EmployeeID:     subject.EmployeeID,
		PresetID:       subject.PresetID,
		Kind:           string(kind),
		KeyFingerprint: activation.Fingerprint(i.Secret, key),
		KeyPrefix:      key.Prefix(),
		ObjectKey:      bound.ObjectKey(),
		InstallationID: subject.InstallationID,
		ChannelKeyHash: activation.HashChannelKey(channelKey),
		ExpiresAt:      now.Add(KeyLifetime),
		Note:           note,
	})
	if err != nil {
		return "", model.Activation{}, err
	}

	if err := i.evictOldest(ctx, actor, subject.EmployeeID, saved.ID); err != nil {
		// Вытеснение не отменяет выпуска: ключ уже выдан и работает, а лишняя
		// строка — это счёт, а не отказ. Сказать об этом всё же надо: молчаливо
		// накопившиеся ключи означают, что правило «не больше трёх» не
		// действует, и заметить это иначе нельзя.
		return key, saved, fmt.Errorf("ключ выпущен, но старые не вытеснены: %w", err)
	}
	return key, saved, nil
}

// grantChannelKey добавляет ключ доступа машины к действующим и обновляет то,
// что машина забирает по нему.
func (i *Issuer) grantChannelKey(ctx context.Context, subject storage.IssueSubject, channelKey string) error {
	if i.Machines == nil {
		return nil
	}

	grants := []ChannelKeyGrant{{
		Hash:     activation.HashChannelKey(channelKey),
		IssuedAt: i.now().UTC().Truncate(time.Second),
	}}
	// Прежний ключ машины остаётся действующим до тех пор, пока новый пакет не
	// заберут: см. выше про порядок.
	if previous, err := i.DB.LiveActivationByInstallation(ctx, subject.InstallationID); err == nil {
		if previous.ChannelKeyHash != "" && previous.ChannelKeyHash != grants[0].Hash {
			grants = append(grants, ChannelKeyGrant{
				Hash:     previous.ChannelKeyHash,
				IssuedAt: previous.IssuedAt.UTC().Truncate(time.Second),
			})
		}
	}

	if err := i.Machines.Keys(ctx, subject.InstallationID, grants); err != nil {
		return err
	}
	return i.Machines.Access(ctx, subject.InstallationID, subject.PresetPublicID, subject.AdminPassword)
}

// evictOldest держит число невостребованных ключей в пределах MaxPendingKeys.
func (i *Issuer) evictOldest(ctx context.Context, actor *int64, employeeID, issuedID int64) error {
	pending, err := i.DB.UnfetchedActivations(ctx, employeeID)
	if err != nil {
		return err
	}
	for len(pending) > MaxPendingKeys {
		oldest := pending[0]
		pending = pending[1:]
		if err := i.DB.SupersedeActivation(
			ctx, actor, oldest.ID, &issuedID, "ключ вытеснен новым"); err != nil {
			return err
		}
	}
	return nil
}

func (i *Issuer) now() time.Time {
	if i.Now != nil {
		return i.Now()
	}
	return time.Now()
}

// StalePending гасит невостребованные ключи сотрудника — потому что данные, с
// которыми они собраны, больше не те.
//
// Нужно потому, что пакет запечатывается и выкладывается **в момент выпуска**:
// номер, SIP-пароль и предустановка застывают в нём такими, какими были тогда.
// Правка карточки после выдачи ключа их не догоняет, и сотрудник, введя ключ
// назавтра, поднимает рабочее место со старым добавочным — молча и с виду
// успешно. Панель до 27 августа 2026 отвечала на это строкой во всплывающем
// сообщении: «если ключ ещё не использован, выпустите новый». Строку легко не
// увидеть, а цена промаха — машина под чужим номером.
//
// **Гасится удалением объекта, а не отметкой в базе.** Ключ работает ровно
// потому, что запечатанный пакет лежит в бакете: Worker отдаёт его, не
// спрашивая панель. Отметка `superseded_at` без удаления не остановила бы
// ничего и сделала бы базу лгущей — поэтому порядок здесь строгий, сперва
// бакет, потом база, и при отказе бакета база не трогается вовсе.
//
// Забранные ключи не трогаются: за ними стоит живая машина, и её настройки
// догоняет линия предустановок. Меняют им номер перепрошивкой, а не этим.
//
// Возвращает, сколько ключей погашено.
func (i *Issuer) StalePending(ctx context.Context, actor *int64, employeeID int64, reason string) (int, error) {
	if i.Bin == nil {
		return 0, fmt.Errorf("гасить нечем: панели не выдан доступ на удаление в бакете")
	}

	pending, err := i.DB.UnfetchedActivations(ctx, employeeID)
	if err != nil {
		return 0, err
	}

	var stale int
	for _, key := range pending {
		if err := i.Bin.Delete(ctx, key.ObjectKey); err != nil {
			return stale, fmt.Errorf("ключ %d не погашен, он ещё работает: %w", key.ID, err)
		}
		if err := i.DB.SupersedeActivation(ctx, actor, key.ID, nil, reason); err != nil {
			return stale, err
		}
		stale++
	}
	return stale, nil
}
