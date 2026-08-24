package storage

import "errors"

var (
	// ErrNotFound — записи нет.
	ErrNotFound = errors.New("не найдено")

	// ErrNumberTaken — номер уже за кем-то закреплён.
	//
	// Отдельная ошибка, а не общая: «занят» означает, что кто-то прямо сейчас
	// снимает по нему звонки, и разбирается это не так, как опечатка в форме.
	ErrNumberTaken = errors.New("номер уже закреплён за другим сотрудником")

	// ErrNumberRetired — номер выведен из обращения.
	ErrNumberRetired = errors.New("номер выведен из обращения")

	// ErrEmployeeDismissed — сотрудник уволен.
	ErrEmployeeDismissed = errors.New("сотрудник уволен")
)
