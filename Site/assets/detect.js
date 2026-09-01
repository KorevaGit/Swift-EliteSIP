/* Определение архитектуры Mac.
 *
 * Задача сайта — чтобы человек взял правильную сборку, не зная, что такое
 * архитектура процессора. Надёжного способа спросить об этом у браузера нет:
 * в userAgent у Apple Silicon по-прежнему написано «Intel Mac OS X», это не
 * ошибка Apple, а совместимость.
 *
 * Работающий признак — имя видеоядра из WebGL: у Apple Silicon это «Apple
 * GPU» или «Apple M…», у старых машин — Intel, AMD или Radeon. Признак
 * косвенный, поэтому он **только отмечает** нужную сборку. Обе остаются на
 * странице с настоящими кнопками, и без JS страница работает так же — просто
 * без отметки. Спрятать одну из двух было бы ошибкой: ошибись определение,
 * человек остался бы без выхода.
 */
(function () {
    "use strict";

    function renderer() {
        try {
            var c = document.createElement("canvas");
            var gl = c.getContext("webgl") || c.getContext("experimental-webgl");
            if (!gl) return "";
            var dbg = gl.getExtension("WEBGL_debug_renderer_info");
            var name = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
            return String(name || "");
        } catch (e) {
            return "";
        }
    }

    function guess() {
        if (!/Mac/i.test(navigator.platform || navigator.userAgent || "")) return null;
        var r = renderer();
        if (/apple\s*(gpu|m\d)/i.test(r)) return "arm64";
        if (/intel|iris|amd|radeon|nvidia|geforce/i.test(r)) return "x86_64";
        return null;
    }

    var arch = guess();
    if (!arch) return;

    var pick = document.querySelector('[data-arch="' + arch + '"]');
    if (!pick) return;
    pick.classList.add("is-live");

    /* Заголовок договаривает то, что показала отметка. Разметка держит оба
       варианта, скрипт только переключает — без JS страница осмысленна, а не
       обрублена. */
    var head = document.querySelector("[data-headline]");
    if (!head) return;
    var known = head.querySelector("[data-when-known]");
    var unknown = head.querySelector("[data-when-unknown]");
    var slot = known && known.querySelector("[data-arch-slot]");
    if (!known || !unknown || !slot) return;

    slot.textContent = pick.getAttribute("data-arch-name") || "";
    unknown.hidden = true;
    known.hidden = false;
})();
