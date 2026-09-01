/* Кнопка «скопировать» у контрольной суммы.
 *
 * Сумма нужна редко, но когда нужна — переписывать её руками невозможно.
 * Кнопка сообщает результат словом, а не только цветом: у человека может не
 * различаться цвет, а «скопировано» читается всегда.
 */
(function () {
    "use strict";
    var idle = "Скопировать";
    document.querySelectorAll("[data-copy]").forEach(function (btn) {
        btn.addEventListener("click", function () {
            var value = document.getElementById(btn.getAttribute("data-copy"));
            if (!value) return;
            var text = value.textContent.trim();
            var done = function () {
                btn.textContent = "Скопировано";
                btn.setAttribute("data-state", "done");
                setTimeout(function () {
                    btn.textContent = idle;
                    btn.removeAttribute("data-state");
                }, 2000);
            };
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(done, function () {
                    btn.textContent = "Не вышло — выделите вручную";
                });
            } else {
                var sel = window.getSelection();
                var range = document.createRange();
                range.selectNodeContents(value);
                sel.removeAllRanges();
                sel.addRange(range);
                btn.textContent = "Выделено — нажмите ⌘C";
            }
        });
    });
})();
