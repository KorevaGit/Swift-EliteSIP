package storage

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/koreva/elitesip-site/internal/model"
)

// Предустановку убирают, только когда за ней никого нет.
//
// Иначе сотрудник остался бы с ключом, который не из чего собрать, и узналось
// бы это при первой попытке его выпустить — то есть при человеке, которому
// ключ обещали здесь и сейчас.
func TestArchivePresetRefusesWhileEmployeesHoldIt(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	ctx := context.Background()
	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	employee, err := db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Пётр Смирнов", Number: "172", PresetID: &preset.ID,
	})
	if err != nil {
		t.Fatalf("CreateEmployee: %v", err)
	}

	if err := db.ArchivePreset(ctx, nil, preset.ID); !errors.Is(err, ErrPresetInUse) {
		t.Fatalf("убрана занятая предустановка: %v", err)
	}

	// Человека убрали — теперь можно.
	if err := db.DeleteEmployee(ctx, nil, employee.ID); err != nil {
		t.Fatalf("DeleteEmployee: %v", err)
	}
	if err := db.ArchivePreset(ctx, nil, preset.ID); err != nil {
		t.Fatalf("ArchivePreset: %v", err)
	}

	live, err := db.ListPresets(ctx, false)
	if err != nil {
		t.Fatalf("ListPresets: %v", err)
	}
	if len(live) != 0 {
		t.Errorf("убранная предустановка осталась в списке: %d", len(live))
	}

	// В файл на R2 она больше не едет: машине нечего было бы применять.
	entries, err := db.BundleEntries(ctx, nil)
	if err != nil {
		t.Fatalf("BundleEntries: %v", err)
	}
	for _, e := range entries {
		if e.PresetID == preset.ID {
			t.Error("убранная предустановка попала в файл")
		}
	}

	// А в журнале остаётся имя: по нему отвечают на «что стояло на машине».
	log, err := db.AuditPage(ctx, AuditFilter{Action: "предустановка убрана", Limit: 5})
	if err != nil {
		t.Fatalf("AuditPage: %v", err)
	}
	if len(log) != 1 || log[0].Details != "Менеджер" {
		t.Errorf("в журнале нет имени убранной предустановки: %+v", log)
	}
}
