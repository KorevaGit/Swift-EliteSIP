package panel

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/koreva/elitesip-site/internal/storage"
)

// Sweeper убирает за собой в бакете.
//
// Уборка существует не ради опрятности. Пакет активации — это SIP-пароль
// рабочего места и его настройки, зашифрованные шестидесятибитным ключом.
// Пролежав год, он превращается в ставку на то, что ключ никуда не утёк за это
// время; убранный через двое суток — не превращается ни во что.
//
// Срок исполняется в двух местах сразу, и одного из них мало. Worker
// отказывает по возрасту объекта — это работает, даже когда панель лежит, но
// пакетов из бакета не убирает. Уборка убирает — но только пока панель жива.
type Sweeper struct {
	DB    *storage.DB
	Store Store

	Now func() time.Time
}

// SweepResult — что дал один заход.
type SweepResult struct {
	Packages int // пакетов унесено
	Marks    int // отметок унесено вместе с ними
	Orphans  int // осиротевших отметок вычищено по сроку
}

// Sweep уносит то, чему в бакете делать больше нечего.
//
// Отказ одного объекта не роняет заход целиком: бакет отвечает по сети, и
// одна неудача не должна лишать уборки все остальные. Неубранное останется
// лежать и уберётся на следующем заходе — уборка идёт по расписанию, а не один
// раз.
func (s *Sweeper) Sweep(ctx context.Context) (SweepResult, error) {
	var result SweepResult

	packages, marks, err := s.sweepPackages(ctx)
	if err != nil {
		return result, err
	}
	result.Packages = packages
	result.Marks = marks

	orphans, err := s.sweepOrphanMarks(ctx)
	if err != nil {
		return result, err
	}
	result.Orphans = orphans

	return result, nil
}

// sweepPackages уносит пакеты, идя от базы.
//
// От базы, а не перечнем бакета: в базе лежит ответ на «этот пакет ещё нужен»,
// а в бакете только имена. Проход по бакету пришлось бы сверять с той же базой,
// только наоборот и дороже.
func (s *Sweeper) sweepPackages(ctx context.Context) (int, int, error) {
	now := s.now()

	targets, err := s.DB.SweepablePackages(ctx, now)
	if err != nil {
		return 0, 0, err
	}

	var packages, marks int
	for _, target := range targets {
		if err := s.Store.Delete(ctx, target.ObjectKey); err != nil {
			continue
		}

		// Отметка забранного уносится **вместе с пакетом**, и только его: она
		// уже разобрана панелью — иначе fetched_at был бы пуст и строка сюда
		// не попала бы. У незабранного отметки нет вовсе.
		if target.Fetched {
			name := strings.TrimPrefix(target.ObjectKey, packagePrefix)
			if err := s.Store.Delete(ctx, takenPrefix+name); err == nil {
				marks++
			}
		}

		if err := s.DB.MarkPackageRemoved(ctx, target.ID, now); err != nil {
			continue
		}
		packages++
	}
	return packages, marks, nil
}

// sweepOrphanMarks вычищает отметки, которым не соответствует строка в базе.
//
// Такие ставит всякий промах: запрос по адресу унесённого пакета, по
// просроченному, по опечатке в ключе. Worker столбит **до** того, как выяснит,
// что отдавать нечего, — и отметка остаётся лежать. Уборка, которая ходит от
// базы, до неё не дотянется никогда: строки, на которую она ссылалась бы, не
// существовало вовсе.
//
// **Отметка не снимается, пока лежит парный пакет.** Она и есть замок
// одноразовости: сняв её с живого пакета, уборка перезарядила бы ключ спустя
// недели после выдачи. У осиротевшей пакета нет по определению, так что
// условие здесь бесплатное — но проверять его надо, а не рассуждать о нём.
func (s *Sweeper) sweepOrphanMarks(ctx context.Context) (int, error) {
	names, err := s.Store.List(ctx, takenPrefix)
	if err != nil {
		return 0, err
	}
	if len(names) == 0 {
		return 0, nil
	}

	known, err := s.DB.KnownObjectNames(ctx)
	if err != nil {
		return 0, err
	}

	packages, err := s.Store.List(ctx, packagePrefix)
	if err != nil {
		return 0, err
	}
	alive := make(map[string]bool, len(packages))
	for _, key := range packages {
		alive[key] = true
	}

	now := s.now()
	count := 0
	for _, key := range names {
		name := strings.TrimPrefix(key, takenPrefix)
		if known[packagePrefix+name] || alive[packagePrefix+name] {
			continue
		}

		// Возраст берётся из самой отметки: перечень бакета времени не даёт, а
		// заводить ради него второй способ узнать то же самое незачем.
		data, err := s.Store.Get(ctx, key)
		if err != nil {
			continue
		}
		var mark struct {
			TakenAt string `json:"taken_at"`
		}
		if err := json.Unmarshal(data, &mark); err != nil {
			continue
		}
		at, err := time.Parse(time.RFC3339, mark.TakenAt)
		if err != nil {
			continue
		}
		if now.Sub(at) < KeyLifetime {
			continue
		}

		if err := s.Store.Delete(ctx, key); err != nil {
			continue
		}
		count++
	}
	return count, nil
}

func (s *Sweeper) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}
