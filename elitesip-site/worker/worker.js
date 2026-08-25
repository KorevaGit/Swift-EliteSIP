/* Раздача EliteSIP: обновления, предустановки, пакеты активации, отзывы.
 *
 * Бакет R2 приватный и наружу не смотрит вовсе: единственный путь к нему —
 * через этот Worker.
 *
 * **Авторизация разная по приставкам, и это главное изменение 25 августа 2026.**
 * До него пара была одна на всё, лежала открытым текстом в каждом бандле — и
 * уволенный сотрудник с копией `.app` тянул настройки конторы бесконечно, а
 * отрезать его было нечем: сменить пару значит пересобрать приложение на всех
 * тридцати машинах.
 *
 *   - выпуски и пакеты активации — общая пара; на выпусках её и хватает, их
 *     целостность держит подпись EdDSA, а пакет защищён шифрованием и
 *     невыводимым адресом;
 *   - предустановки, доступ и отзыв — помашинный ключ, выданный в пакете
 *     активации. Панель убирает machines/<id> — машина перестаёт получать
 *     что бы то ни было. Отсюда и взялся отзыв как техническое действие.
 *
 * Ещё три вещи, которых бакет сам не умеет:
 *
 *   1. пакет активации отдаётся **один раз** — здесь живёт одноразовость ключа;
 *   2. пакет старше двух суток не отдаётся вовсе;
 *   3. заход машины оставляет отметку о том, кто приходил и на какой ревизии.
 *
 * Отметки складываются в тот же бакет, а не в D1 или KV. Причина не в
 * бережливости: панель ходит в R2 и так, по S3, — и разбирает отметки тем же
 * доступом, которым выкладывает. Отдельное хранилище означало бы второй канал
 * со вторым секретом, то есть второе место, где можно ошибиться с доступом.
 *
 * Ни сборки, ни зависимостей: файл читается целиком за десять минут, и это его
 * главное свойство. Панель держится того же правила.
 */

/* Realm обязан оставаться "restricted" — тем же, что отдаёт стенд на Caddy.
 * URLSession в macOS подставляет заранее сохранённую пару только при точном
 * совпадении realm; с другим значением приложение молча получит 401. */
const REALM = "restricted";

/* Раскладка бакета.
 *
 * Приставки разведены затем, чтобы панель перечисляла отметки, не вычитая из
 * перечня пакеты, архивы выпусков и файл предустановок. */
const PACKAGE_PREFIX = "activations/";
const TAKEN_PREFIX = "taken/";
const SEEN_PREFIX = "seen/";
const MACHINE_PREFIX = "machines/";
const ACCESS_PREFIX = "access/";
const REVOKED_PREFIX = "revoked/";
const BUNDLE_KEY = "presets/current.json";

/* Сколько живёт пакет активации. Тот же срок, что у панели: двое суток.
 *
 * Проверяется здесь, а не только там, потому что панель может лежать, а пакет
 * — это SIP-пароль рабочего места. Панель тем временем уносит просроченные из
 * бакета; одного из двух мало. */
const PACKAGE_LIFETIME_MS = 48 * 60 * 60 * 1000;

/* Заголовки, которыми машина сообщает о себе.
 *
 * Заголовками, а не строкой запроса: адрес файла предустановок обязан
 * оставаться одним и тем же для всех машин, иначе кэш раздаёт его каждой
 * заново.
 *
 * X-EliteSIP-Installation здесь больше нет: идентификатор приезжает именем
 * пользователя в Basic и **проверен**, а не объявлен. Два места для одного
 * факта однажды разошлись бы. */
const H_APP = "x-elitesip-app";
const H_SCHEMA = "x-elitesip-schema";
const H_REVISION = "x-elitesip-revision";

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("405 Method Not Allowed\n", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    const url = new URL(request.url);
    const key = decodeURIComponent(url.pathname.replace(/^\/+/, ""));

    // Листинга нет намеренно: канал раздачи не обязан рассказывать, какие
    // выпуски вообще существуют. Источник правды — appcast.
    if (key === "") return notFound();

    // Внутреннее дело панели и Worker'а. Наружу не раздаётся ничего из этого:
    // machines/ — это хеши ключей доступа, а перечень чужих installation_id
    // машинам знать незачем.
    if (
      key.startsWith(TAKEN_PREFIX) ||
      key.startsWith(SEEN_PREFIX) ||
      key.startsWith(MACHINE_PREFIX)
    ) {
      return notFound();
    }

    // Помашинное — сначала: у него своя авторизация, и общая пара сюда не
    // пускает.
    if (key === BUNDLE_KEY) {
      return withMachine(request, env, (id) => serveBundle(key, request, env, ctx, id));
    }
    if (key.startsWith(ACCESS_PREFIX)) {
      return withMachine(request, env, (id) => serveOwn(key, ACCESS_PREFIX, id, request, env));
    }
    if (key.startsWith(REVOKED_PREFIX)) {
      return withMachine(request, env, (id) => serveOwn(key, REVOKED_PREFIX, id, request, env));
    }

    // Всё остальное — на общей паре.
    if (!authorizedShared(request, env)) return unauthorized();

    if (key.startsWith(PACKAGE_PREFIX)) {
      return servePackage(key, request, env);
    }
    return serveFile(key, request, env);
  },
};

/* ------------------------------------------------------------- активация */

/* Пакет активации отдаётся ровно один раз.
 *
 * Порядок здесь — половина всего смысла. Отметка ставится **до** выдачи, и
 * ставится условной записью: «создай, если такого объекта ещё нет». Кто
 * записал — тот и отдаёт; остальные получают отказ.
 *
 * Обратный порядок — отдать, потом отметить — оставлял бы щель ровно на время
 * ответа, и два одновременных запроса по одному ключу получили бы пакет оба.
 *
 * Цена выбранного порядка названа прямо: оборвавшаяся закачка сжигает ключ.
 * Это принято сознательно — выпустить новый ключ стоит одного нажатия, а
 * сработавший дважды ключ стоит рабочего места.
 *
 * **Отметка говорит, чем кончилось.** Столбим с `delivered: false`, и только
 * отдав пакет, переписываем на `true`. Без этого панель считала бы забранным и
 * то, чего не отдавали: опоздавший сотрудник получал бы 410, а в панели его
 * место числилось бы настроенным.
 */
async function servePackage(key, request, env) {
  const name = key.slice(PACKAGE_PREFIX.length);

  if (!(await claim(env, key, name, request))) {
    /* 410, а не 404: пакет существовал. Приложению всё равно — оно показывает
     * одно и то же на оба ответа, — но в журнале Cloudflare разница между «не
     * тот ключ» и «уже забрали» видна. */
    return gone();
  }

  const object = await env.BUCKET.get(key);
  if (object === null) return notFound();

  /* Просроченный неотличим снаружи от забранного, и это намеренно: человеку
   * оба ответа означают одно — нужен новый ключ. Разницу показывает панель из
   * своей базы. */
  if (object.uploaded && Date.now() - object.uploaded.getTime() > PACKAGE_LIFETIME_MS) {
    return gone();
  }

  await mark(env, TAKEN_PREFIX + name, {
    format: 2,
    object_key: key,
    delivered: true,
    taken_at: new Date().toISOString(),
    app_version: header(request, H_APP).slice(0, 64),
    schema_version: number(header(request, H_SCHEMA)),
  });

  const headers = baseHeaders();
  headers.set("Content-Type", "application/octet-stream");
  /* Никакого кэша: пакет отдаётся один раз, и закэшированная копия сделала бы
   * одноразовость бессмысленной. Именно здесь общее правило «всё, кроме .xml,
   * неизменяемо» дало бы обратное тому, что нужно. */
  headers.set("Cache-Control", "no-store");

  return new Response(request.method === "HEAD" ? null : object.body, { headers });
}

/* claim пытается застолбить пакет за собой.
 *
 * Возвращает true, если отметку поставили мы. Условная запись — единственное,
 * что здесь работает: `head` с последующей записью оставляет ту же щель, ради
 * закрытия которой всё и затевалось.
 */
async function claim(env, key, name, request) {
  try {
    const written = await env.BUCKET.put(
      TAKEN_PREFIX + name,
      JSON.stringify({
        format: 2,
        object_key: key,
        delivered: false,
        taken_at: new Date().toISOString(),
        app_version: header(request, H_APP).slice(0, 64),
        schema_version: number(header(request, H_SCHEMA)),
      }),
      {
        httpMetadata: { contentType: "application/json" },
        onlyIf: { etagDoesNotMatch: "*" },
      }
    );
    /* Условная запись, которой не дали пройти, возвращает null, а не бросает.
     * Проверяются оба исхода: какой именно случится, зависит от версии среды, а
     * полагаться на один — значит однажды раздать пакет дважды. */
    return written !== null;
  } catch {
    return false;
  }
}

async function mark(env, key, body) {
  await env.BUCKET.put(key, JSON.stringify(body), {
    httpMetadata: { contentType: "application/json" },
  });
}

/* --------------------------------------------------------- предустановки */

/* Файл предустановок отдаётся всем машинам, у которых есть свой ключ, и
 * сколько угодно раз.
 *
 * Отметка о машине пишется **после** ответа, через waitUntil: запись в бакет не
 * должна задерживать раздачу и уж тем более не должна её ронять. Машина, не
 * получившая файл из-за неудавшейся отметки, — это машина, которая не узнала о
 * смене адреса АТС.
 */
async function serveBundle(key, request, env, ctx, installation) {
  const object = await env.BUCKET.get(key);
  if (object === null) return notFound();

  ctx.waitUntil(recordSeen(env, installation, request));

  const headers = baseHeaders();
  object.writeHttpMetadata(headers);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("ETag", object.httpEtag);
  /* Короткий кэш: машина опрашивает раз в два часа, и правка обязана доезжать
   * за этот срок, а не за срок кэша. Годовой immutable, которым раздаются
   * архивы выпусков, здесь означал бы, что смена адреса АТС не доедет никогда. */
  headers.set("Cache-Control", "public, max-age=60, must-revalidate");

  return new Response(request.method === "HEAD" ? null : object.body, { headers });
}

/* serveOwn отдаёт машине то, что принадлежит ей одной.
 *
 * Совпадение имени объекта с проверенным installation_id — не формальность:
 * без него машина с любым действующим ключом читала бы административный пароль
 * чужой предустановки, и всё разделение доступа стало бы мнимым.
 *
 * Ответ на несуществующий отзыв — 404, и это часть договора: **отсутствие
 * ответа никогда не означает отзыв.** Машина, которой не ответили, работает
 * дальше; сбрасывается она только по подписанному объекту.
 */
async function serveOwn(key, prefix, installation, request, env) {
  if (key.slice(prefix.length) !== installation) return notFound();

  const object = await env.BUCKET.get(key);
  if (object === null) return notFound();

  const headers = baseHeaders();
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");

  return new Response(request.method === "HEAD" ? null : object.body, { headers });
}

/* Отметка — состояние машины, а не череда событий.
 *
 * Перезапись, а не дозапись: панели нужен ответ на «где машина сейчас», а не
 * полторы тысячи строк в день о том, что она всё ещё жива.
 */
async function recordSeen(env, installation, request) {
  await mark(env, SEEN_PREFIX + installation, {
    format: 1,
    installation_id: installation,
    last_seen_at: new Date().toISOString(),
    app_version: header(request, H_APP).slice(0, 64),
    schema_version: number(header(request, H_SCHEMA)),
    preset_revision: number(header(request, H_REVISION)),
  });
}

/* ------------------------------------------------------------ обновления */

/* Всё остальное — appcast и архивы выпусков. Раздаётся ровно так, как
 * раздавалось до этапа 5: с частичными запросами, ради которых Sparkle
 * докачивает оборвавшуюся загрузку, и с прежними сроками кэша.
 */
async function serveFile(key, request, env) {
  // R2 заполняет object.range и для полного запроса, поэтому решать по нему
  // нельзя: получится 206 на запрос, в котором Range не просили, а это
  // некорректный HTTP. Признак — только заголовок запроса.
  const rangeRequested = request.headers.has("Range");
  const options = {};
  if (rangeRequested) options.range = request.headers;

  const object = await env.BUCKET.get(key, options);
  if (object === null) return notFound();

  const headers = baseHeaders();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);

  if (key.endsWith(".xml")) {
    // Appcast меняется при каждом выпуске и обязан доезжать быстро.
    headers.set("Content-Type", "application/xml; charset=utf-8");
    headers.set("Cache-Control", "public, max-age=300, must-revalidate");
  } else {
    // Архивы неизменяемы: имя файла содержит версию и срез.
    headers.set("Cache-Control", "public, max-age=31536000, immutable");
  }

  if (rangeRequested && object.range && object.size !== undefined) {
    const { offset = 0, length } = object.range;
    const end = length === undefined ? object.size - 1 : offset + length - 1;
    headers.set("Content-Range", `bytes ${offset}-${end}/${object.size}`);
    return new Response(request.method === "HEAD" ? null : object.body, {
      status: 206,
      headers,
    });
  }

  return new Response(request.method === "HEAD" ? null : object.body, { headers });
}

/* ------------------------------------------------------------------ доступ */

function unauthorized() {
  return new Response("401 Unauthorized\n", {
    status: 401,
    headers: {
      "WWW-Authenticate": `Basic realm="${REALM}"`,
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

// Сравнение постоянного времени: обычное === выдаёт длину общего префикса
// по времени ответа, и пара подбирается посимвольно.
function equals(a, b) {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.byteLength !== eb.byteLength) return false;
  return crypto.subtle.timingSafeEqual(ea, eb);
}

function basic(request) {
  const header = request.headers.get("Authorization");
  if (!header || !header.startsWith("Basic ")) return null;
  let decoded;
  try {
    /* atob отдаёт строку, где каждый знак — байт (latin1). Пропустить её через
     * TextDecoder обязательно: без этого пара с любым знаком вне ASCII
     * сравнивается с мусором и не подходит никогда. Нашлось проверкой —
     * вживую пара оказалась латинской, и ошибка ждала бы того дня, когда
     * кто-нибудь задаст пароль по-русски. */
    const bytes = Uint8Array.from(atob(header.slice(6)), (c) => c.charCodeAt(0));
    decoded = new TextDecoder().decode(bytes);
  } catch {
    return null;
  }
  const split = decoded.indexOf(":");
  if (split < 0) return null;
  return { user: decoded.slice(0, split), pass: decoded.slice(split + 1) };
}

/* Общая пара из бандла. Открывает выпуски и пакеты активации — и больше ничего. */
function authorizedShared(request, env) {
  const pair = basic(request);
  if (pair === null) return false;
  // Оба сравнения выполняются всегда, без короткого замыкания по &&.
  const userOk = equals(pair.user, env.AUTH_USER);
  const passOk = equals(pair.pass, env.AUTH_PASS);
  return userOk && passOk;
}

/* withMachine пускает дальше только машину, предъявившую свой ключ.
 *
 * Пользователь — installation_id, пароль — ключ канала из пакета активации.
 * Сверяется он с machines/<id>, где панель держит SHA-256 действующих ключей.
 * Ключей бывает два: при перепрошивке недолгое время действуют и старый, и
 * новый — машина ещё не забрала пакет, но работать обязана.
 *
 * Растяжения тут нет и не нужно: ключ канала — тридцать два случайных байта,
 * перебирать в нём нечего. Растяжение нужно ключу активации, у которого
 * шестьдесят бит.
 */
async function withMachine(request, env, handler) {
  const pair = basic(request);
  if (pair === null || !looksLikeID(pair.user)) return unauthorized();

  const record = await env.BUCKET.get(MACHINE_PREFIX + pair.user);
  if (record === null) return unauthorized();

  let keys;
  try {
    keys = (await record.json()).keys || [];
  } catch {
    return unauthorized();
  }

  const presented = await sha256hex(pair.pass);
  let ok = false;
  // Перебираются все ключи целиком, без выхода по первому совпадению: ранний
  // выход выдавал бы временем ответа, какой по счёту ключ подошёл.
  for (const key of keys) {
    if (typeof key.hash === "string" && equals(key.hash, presented)) ok = true;
  }
  if (!ok) return unauthorized();

  return handler(pair.user);
}

async function sha256hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/* ------------------------------------------------------------------ мелочь */

function baseHeaders() {
  const headers = new Headers();
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  return headers;
}

function notFound() {
  return new Response("404 Not Found\n", {
    status: 404,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function gone() {
  return new Response("410 Gone\n", {
    status: 410,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function header(request, name) {
  return (request.headers.get(name) || "").trim();
}

function number(raw) {
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) ? value : null;
}

/* Идентификатор машины уходит в имя объекта, поэтому проверяется по составу, а
 * не по длине: точки и косые в нём означали бы чтение не оттуда. */
function looksLikeID(value) {
  return /^[A-Za-z0-9_-]{8,64}$/.test(value);
}
