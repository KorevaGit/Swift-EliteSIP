/* Немного поведения, которого нельзя добиться разметкой.
 *
 * Ни сборки, ни зависимостей: файл читается целиком за минуту, и это его
 * главное свойство. Всё, что можно сделать формой и ссылкой, сделано ими.
 */

(function () {
    "use strict";

    /* Оформление: как в системе → светлое → тёмное → как в системе.
     *
     * Три состояния, а не два: «как в системе» должно оставаться достижимым,
     * иначе выбравший однажды тёмную тему больше никогда не вернётся к
     * системной, не чистя хранилище браузера. */
    var order = ["auto", "light", "dark"];
    var names = { auto: "как в системе", light: "светлое", dark: "тёмное" };

    function currentTheme() {
        var stored = null;
        try { stored = localStorage.getItem("elitesip-theme"); } catch (e) { /* приватный режим */ }
        return order.indexOf(stored) === -1 ? "auto" : stored;
    }

    function applyTheme(theme) {
        if (theme === "auto") {
            document.documentElement.removeAttribute("data-theme");
        } else {
            document.documentElement.setAttribute("data-theme", theme);
        }
        try { localStorage.setItem("elitesip-theme", theme); } catch (e) { /* приватный режим */ }

        document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
            button.title = "Оформление: " + names[theme];
        });
    }

    document.addEventListener("click", function (event) {
        var toggle = event.target.closest("[data-theme-toggle]");
        if (toggle) {
            var next = order[(order.indexOf(currentTheme()) + 1) % order.length];
            applyTheme(next);
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

        /* Замок на адресах АТС и стуке.
           Снимается насовсем до перезагрузки страницы: запирать обратно нечего —
           замок сторожит случайное движение, а не злой умысел. */
        var unlocker = event.target.closest("[data-unlock]");
        if (unlocker) {
            event.preventDefault();
            var name = unlocker.getAttribute("data-unlock");
            var guarded = document.querySelector('[data-lockable="' + name + '"]');
            if (guarded) {
                guarded.removeAttribute("inert");
                guarded.classList.remove("locked");
            }
            var section = unlocker.closest("details");
            if (section) {
                var mark = section.querySelector(".lock-mark");
                if (mark) { mark.remove(); }
            }
            unlocker.remove();
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

    applyTheme(currentTheme());
})();
