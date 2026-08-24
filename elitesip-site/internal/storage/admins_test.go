package storage

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSessionRoundTrip(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	admin, err := db.CreateAdmin(ctx, nil, "eugene", "хеш")
	if err != nil {
		t.Fatalf("CreateAdmin: %v", err)
	}

	token, err := db.StartSession(ctx, admin.ID)
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}

	got, err := db.AdminBySession(ctx, token)
	if err != nil {
		t.Fatalf("AdminBySession: %v", err)
	}
	if got.ID != admin.ID {
		t.Errorf("сеанс отдал администратора %d, ожидался %d", got.ID, admin.ID)
	}

	if err := db.EndSession(ctx, token); err != nil {
		t.Fatalf("EndSession: %v", err)
	}
	if _, err := db.AdminBySession(ctx, token); !errors.Is(err, ErrNotFound) {
		t.Errorf("завершённый сеанс всё ещё пускает: %v", err)
	}
}

// В базе лежит хеш токена: украденная база не даёт готовых входов.
func TestSessionTokenIsNotStored(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	admin, _ := db.CreateAdmin(ctx, nil, "eugene", "хеш")
	token, err := db.StartSession(ctx, admin.ID)
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}

	var stored string
	if err := db.QueryRow(`SELECT token_hash FROM sessions`).Scan(&stored); err != nil {
		t.Fatalf("прочитать сеанс: %v", err)
	}
	if stored == token {
		t.Fatal("в базе лежит сам токен")
	}
}

func TestExpiredSessionIsRejected(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	admin, _ := db.CreateAdmin(ctx, nil, "eugene", "хеш")
	token, _ := db.StartSession(ctx, admin.ID)

	past := time.Now().Add(-time.Minute)
	if _, err := db.Exec(`UPDATE sessions SET expires_at = ?`, formatTime(past)); err != nil {
		t.Fatalf("подмена срока: %v", err)
	}

	if _, err := db.AdminBySession(ctx, token); !errors.Is(err, ErrNotFound) {
		t.Errorf("истёкший сеанс пускает: %v", err)
	}
	if err := db.PurgeExpiredSessions(ctx); err != nil {
		t.Fatalf("PurgeExpiredSessions: %v", err)
	}
	var left int
	db.QueryRow(`SELECT COUNT(*) FROM sessions`).Scan(&left)
	if left != 0 {
		t.Errorf("после уборки осталось сеансов: %d", left)
	}
}

// Гасят администратора обычно затем, чтобы он перестал входить прямо сейчас, а
// не когда у него истечёт сеанс.
func TestDisabledAdminLosesSessionsImmediately(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	admin, _ := db.CreateAdmin(ctx, nil, "eugene", "хеш")
	token, _ := db.StartSession(ctx, admin.ID)

	if err := db.DisableAdmin(ctx, nil, admin.ID); err != nil {
		t.Fatalf("DisableAdmin: %v", err)
	}
	if _, err := db.AdminBySession(ctx, token); err == nil {
		t.Fatal("отключённый администратор всё ещё внутри")
	}
}

// Пароль меняют в том числе потому, что он утёк, — оставленный жить сеанс
// сделал бы смену бессмысленной.
func TestPasswordChangeDropsSessions(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	admin, _ := db.CreateAdmin(ctx, nil, "eugene", "хеш")
	token, _ := db.StartSession(ctx, admin.ID)

	if err := db.SetAdminPassword(ctx, nil, admin.ID, "новый-хеш"); err != nil {
		t.Fatalf("SetAdminPassword: %v", err)
	}
	if _, err := db.AdminBySession(ctx, token); err == nil {
		t.Fatal("после смены пароля старый сеанс жив")
	}
}

// Панель без администраторов должна предложить завести первого, а не показать
// форму входа, в которую нечего вводить.
func TestAdminCountDrivesFirstRun(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	count, err := db.AdminCount(ctx)
	if err != nil {
		t.Fatalf("AdminCount: %v", err)
	}
	if count != 0 {
		t.Fatalf("на свежей базе администраторов %d", count)
	}

	admin, _ := db.CreateAdmin(ctx, nil, "eugene", "хеш")
	if count, _ = db.AdminCount(ctx); count != 1 {
		t.Errorf("после заведения администраторов %d", count)
	}

	db.DisableAdmin(ctx, nil, admin.ID)
	if count, _ = db.AdminCount(ctx); count != 0 {
		t.Errorf("после отключения администраторов %d", count)
	}
}

func TestLoginIsUnique(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	if _, err := db.CreateAdmin(ctx, nil, "eugene", "хеш"); err != nil {
		t.Fatalf("CreateAdmin: %v", err)
	}
	if _, err := db.CreateAdmin(ctx, nil, "eugene", "другой"); err == nil {
		t.Fatal("два администратора с одним входным именем")
	}
}
