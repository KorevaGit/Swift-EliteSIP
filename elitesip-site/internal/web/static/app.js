/* Немного поведения, которого нельзя добиться разметкой.
 *
 * Ни сборки, ни зависимостей: файл читается целиком за минуту, и это его
 * главное свойство. Всё, что можно сделать формой и ссылкой, сделано ими.
 */

(function () {
    "use strict";

    /* Оформление: светлое ⇄ тёмное.
     *
     * Два состояния, а не три. «Как в системе» отсюда убрано 26 августа
     * 2026: третье состояние было неразличимо на глаз от того из двух, с
     * которым совпадало, и нажатие на кнопку в этот момент выглядело как
     * ничего не сделавшее. Пока выбора не сделали, тема берётся системная —
     * это по-прежнему так, просто отдельной кнопки под это больше нет.
     */
    var names = { light: "светлое", dark: "тёмное" };

    var icons = {
        light: '<circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/>'
             + '<line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/>'
             + '<line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/>'
             + '<line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/>'
             + '<line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>',
        dark: '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>'
    };

    /* Что показано сейчас: выбранное человеком, а до выбора — системное. */
    function currentTheme() {
        var stored = null;
        try { stored = localStorage.getItem("elitesip-theme"); } catch (e) { /* приватный режим */ }
        if (stored === "light" || stored === "dark") { return stored; }
        return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
            ? "dark" : "light";
    }

    function applyTheme(theme) {
        document.documentElement.setAttribute("data-theme", theme);
        try { localStorage.setItem("elitesip-theme", theme); } catch (e) { /* приватный режим */ }

        document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
            button.title = "Оформление: " + names[theme];
            var icon = button.querySelector("[data-theme-icon]");
            if (icon) { icon.innerHTML = icons[theme]; }
        });
    }

    document.addEventListener("click", function (event) {
        var toggle = event.target.closest("[data-theme-toggle]");
        if (toggle) {
            applyTheme(currentTheme() === "dark" ? "light" : "dark");
            return;
        }

        /* Копирование ключа. Ключ показывается один раз, и переписывать его
           руками с экрана — как раз тот случай, когда ошибаются в одном знаке
           и приходят с «ключ не подходит». */
        var copier = event.target.closest("[data-copy]");
        if (copier) {
            var source = document.querySelector(copier.getAttribute("data-copy"));
            if (!source) { return; }
            var text = source.textContent.trim();
            var done = function () {
                var was = copier.textContent;
                copier.textContent = "Скопировано";
                setTimeout(function () { copier.textContent = was; }, 1600);
            };
            if (navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(text).then(done, fallbackCopy.bind(null, text, done));
            } else {
                /* Панель открывают по http внутри сети, а там Clipboard API
                   недоступен — без запасного пути кнопка бы просто молчала. */
                fallbackCopy(text, done);
            }
            return;
        }

        /* Действия, которые трудно отменить, спрашивают подтверждения.
           Коротким вопросом — window.confirm, длинным со списком — окном ниже. */
        var risky = event.target.closest("[data-confirm]");
        if (risky && !window.confirm(risky.getAttribute("data-confirm"))) {
            event.preventDefault();
            return;
        }

        var opener = event.target.closest("[data-dialog]");
        if (opener) {
            event.preventDefault();
            var sheet = document.getElementById(opener.getAttribute("data-dialog"));
            /* showModal, а не open: он забирает фокус и не даёт нажать то, что
               под окном, — а под окном здесь стоит та же кнопка «Удалить». */
            if (sheet && sheet.showModal) { sheet.showModal(); }
            return;
        }

        /* Развернуть спрятанный блок: форма заведения предустановки и форма
           выдачи ключа лежат свёрнутыми и раскрываются кнопкой. Это не
           гармошка со скрытыми настройками — это одно действие, которое не
           должно занимать первый экран у тех, кто пришёл смотреть список. */
        var opener2 = event.target.closest("[data-open]");
        if (opener2) {
            event.preventDefault();
            var block = document.getElementById(opener2.getAttribute("data-open"));
            if (block) {
                block.hidden = false;
                var first = block.querySelector("input, select");
                if (first) { first.focus(); }
            }
            return;
        }

        var closer = event.target.closest("[data-dialog-close]");
        if (closer) {
            event.preventDefault();
            var open = closer.closest("dialog");
            if (open) { open.close(); }
            return;
        }

        /* Добавление строки в список — макросы, очереди, шаги стука. */
        var adder = event.target.closest("[data-add]");
        if (adder) {
            event.preventDefault();
            addRow(adder.getAttribute("data-add"));
            return;
        }

        var remover = event.target.closest("[data-remove]");
        if (remover) {
            event.preventDefault();
            var row = remover.closest("[data-row]");
            if (row) { row.remove(); }
        }
    });

    function fallbackCopy(text, done) {
        var area = document.createElement("textarea");
        area.value = text;
        area.setAttribute("readonly", "");
        area.style.position = "fixed";
        area.style.opacity = "0";
        document.body.appendChild(area);
        area.select();
        try { document.execCommand("copy"); done(); } catch (e) { /* остаётся выделить руками */ }
        document.body.removeChild(area);
    }

    /* Новая строка получает индекс, которого ещё не было.
     *
     * Счётчик, а не длина списка: строки удаляют из середины, и по длине два
     * разных поля однажды получили бы одно имя — правка одной строки уехала бы
     * в другую. */
    var counters = {};

    function addRow(listName) {
        var list = document.querySelector('[data-list="' + listName + '"]');
        var template = document.querySelector('[data-template="' + listName + '"]');
        if (!list || !template) { return; }

        if (counters[listName] === undefined) {
            counters[listName] = list.querySelectorAll("[data-row]").length;
        }
        var index = "n" + (counters[listName]++);

        var html = template.innerHTML.replace(/__INDEX__/g, index);
        var holder = document.createElement("div");
        holder.innerHTML = html.trim();
        var row = holder.firstElementChild;
        list.appendChild(row);

        var firstInput = row.querySelector("input, select");
        if (firstInput) { firstInput.focus(); }
    }

    (function paintToggle() {
        var theme = currentTheme();
        document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
            button.title = "Оформление: " + names[theme];
            var icon = button.querySelector("[data-theme-icon]");
            if (icon) { icon.innerHTML = icons[theme]; }
        });
    })();
})();
