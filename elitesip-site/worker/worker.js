/* Раздача EliteSIP: обновления, предустановки, пакеты активации.
 *
 * Бакет R2 приватный и наружу не смотрит вовсе: единственный путь к нему —
 * через этот Worker, и он требует Basic-авторизацию.
 *
 * Раздача обновлений (M7h) здесь была первой и остаётся главной: appcast и
 * архивы выпусков раздаются ровно так же, как раздавались. Этап 5 панели
 * добавил к ней две вещи, которых бакет сам не умеет:
 *
 *   1. пакет активации отдаётся **один раз** — здесь живёт одноразовость ключа;
 *   2. заход машины за файлом предустановок оставляет отметку о том, кто
 *      приходил, с какой версией и на какой ревизии.
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
const BUNDLE_KEY = "presets/current.json";

/* Заголовки, которыми машина сообщает о себе.
 *
 * Заголовками, а не строкой запроса: адрес файла предустановок обязан
 * оставаться одним и тем же для всех машин, иначе кэш раздаёт его каждой
 * заново — а забирают его тридцать машин каждые полчаса. */
const H_INSTALLATION = "x-elitesip-installation";
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

    if (!authorized(request, env)) return unauthorized();

    const url = new URL(request.url);
    const key = decodeURIComponent(url.pathname.replace(/^\/+/, ""));

    // Листинга нет намеренно: канал раздачи не обязан рассказывать, какие
    // выпуски вообще существуют. Источник правды — appcast.
    if (key === "") return notFound();

    // Отметки — внутреннее дело панели, и наружу они не раздаются. Basic-пара
    // лежит в бандле каждого приложения, то есть «внутри» её знают все машины;
    // перечень чужих installation_id им знать незачем.
    if (key.startsWith(TAKEN_PREFIX) || key.startsWith(SEEN_PREFIX)) {
      return notFound();
    }

    if (key.startsWith(PACKAGE_PREFIX)) {
      return servePackage(key, request, env);
    }
    if (key === BUNDLE_KEY) {
      return serveBundle(key, request, env, ctx);
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
 * Ради закрытия этой щели Worker и дополнен: до неё одноразовость держалась на
 * честном слове.
 *
 * Цена выбранного порядка названа прямо: оборвавшаяся закачка сжигает ключ.
 * Это принято сознательно — выпустить новый ключ стоит одного нажатия, а
 * сработавший дважды ключ стоит рабочего места.
 */
async function servePackage(key, request, env) {
  if (!(await claim(env, key, request))) {
    /* 410, а не 404: пакет существовал. Приложению всё равно — оно показывает
     * одно и то же на оба ответа, — но в журнале Cloudflare разница между «не
     * тот ключ» и «уже забрали» видна. */
    return new Response("410 Gone\n", {
      status: 410,
      headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
    });
  }

  const object = await env.BUCKET.get(key);
  if (object === null) return notFound();

  const headers = new Headers();
  headers.set("Content-Type", "application/octet-stream");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
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
async function claim(env, key, request) {
  const mark = {
    format: 1,
    object_key: key,
    taken_at: new Date().toISOString(),
    installation_id: header(request, H_INSTALLATION).slice(0, 64),
    app_version: header(request, H_APP).slice(0, 64),
    schema_version: number(header(request, H_SCHEMA)),
  };

  try {
    const written = await env.BUCKET.put(
      TAKEN_PREFIX + key.slice(PACKAGE_PREFIX.length),
      JSON.stringify(mark),
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

/* --------------------------------------------------------- предустановки */

/* Файл предустановок отдаётся всем и сколько угодно раз.
 *
 * Отметка о машине пишется **после** ответа, через waitUntil: запись в бакет не
 * должна задерживать раздачу и уж тем более не должна её ронять. Машина, не
 * получившая файл из-за неудавшейся отметки, — это машина, которая не узнала о
 * смене адреса АТС.
 */
async function serveBundle(key, request, env, ctx) {
  const object = await env.BUCKET.get(key);
  if (object === null) return notFound();

  const installation = header(request, H_INSTALLATION);
  if (installation && looksLikeID(installation)) {
    ctx.waitUntil(recordSeen(env, installation, request));
  }

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("ETag", object.httpEtag);
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  /* Короткий кэш: машина опрашивает раз в полчаса, и правка обязана доезжать за
   * этот срок, а не за срок кэша. Годовой immutable, которым раздаются архивы
   * выпусков, здесь означал бы, что смена адреса АТС не доедет никогда. */
  headers.set("Cache-Control", "public, max-age=60, must-revalidate");

  return new Response(request.method === "HEAD" ? null : object.body, { headers });
}

/* Отметка — состояние машины, а не череда событий.
 *
 * Перезапись, а не дозапись: панели нужен ответ на «где машина сейчас», а не
 * полторы тысячи строк в день о том, что она всё ещё жива.
 */
async function recordSeen(env, installation, request) {
  const seen = {
    format: 1,
    installation_id: installation,
    last_seen_at: new Date().toISOString(),
    app_version: header(request, H_APP).slice(0, 64),
    schema_version: number(header(request, H_SCHEMA)),
    preset_revision: number(header(request, H_REVISION)),
  };
  await env.BUCKET.put(SEEN_PREFIX + installation, JSON.stringify(seen), {
    httpMetadata: { contentType: "application/json" },
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

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Strict-Transport-Security", "max-age=31536000; includeSubDomains");

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

function authorized(request, env) {
  const header = request.headers.get("Authorization");
  if (!header || !header.startsWith("Basic ")) return false;
  let decoded;
  try {
    decoded = atob(header.slice(6));
  } catch {
    return false;
  }
  const split = decoded.indexOf(":");
  if (split < 0) return false;
  const user = decoded.slice(0, split);
  const pass = decoded.slice(split + 1);
  // Оба сравнения выполняются всегда, без короткого замыкания по &&.
  const userOk = equals(user, env.AUTH_USER);
  const passOk = equals(pass, env.AUTH_PASS);
  return userOk && passOk;
}

/* ------------------------------------------------------------------ мелочь */

function notFound() {
  return new Response("404 Not Found\n", {
    status: 404,
    headers: { "Content-Type": "text/plain; charset=utf-8" },
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
 * не по длине: точки и косые в нём означали бы запись не туда. */
function looksLikeID(value) {
  return /^[A-Za-z0-9_-]{8,64}$/.test(value);
}
