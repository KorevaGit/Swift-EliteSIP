/* Проверки Worker'а. Запуск: `node --test` в этой папке.
 *
 * Ни vitest, ни miniflare: правило «ни сборки, ни зависимостей» относится и к
 * проверкам. Всё, чего не хватает от среды Cloudflare, — это R2-бакет и одна
 * функция сравнения; и то и другое подставляется здесь на двадцати строках.
 */

import { strict as assert } from "node:assert";
import { test } from "node:test";
import { createHash, timingSafeEqual } from "node:crypto";

// В Node этого нет, в Workers есть. Поведение то же самое.
crypto.subtle.timingSafeEqual ??= (a, b) =>
  timingSafeEqual(Buffer.from(a), Buffer.from(b));

const worker = (await import("./worker.js")).default;

const USER = "elitesip";
const PASS = "пара-из-бандла";
const MACHINE = "8f2c4a1b9d3e5f60";
const CHANNEL_KEY = "a".repeat(64);

/* Бакет: ровно те четыре метода, которыми пользуется worker.js. */
function bucket(initial = {}) {
  const objects = new Map(Object.entries(initial));
  return {
    objects,
    async get(key) {
      const found = objects.get(key);
      if (found === undefined) return null;
      const body = typeof found.body === "string" ? found.body : found.body ?? "";
      return {
        body,
        size: body.length,
        uploaded: found.uploaded ?? new Date(),
        httpEtag: '"etag"',
        writeHttpMetadata() {},
        async json() {
          return JSON.parse(body);
        },
      };
    },
    async put(key, value, options) {
      if (options?.onlyIf?.etagDoesNotMatch === "*" && objects.has(key)) return null;
      objects.set(key, { body: value });
      return { key };
    },
  };
}

function sha256hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

function machineRecord(hashes) {
  return {
    body: JSON.stringify({
      format: 1,
      installation_id: MACHINE,
      keys: hashes.map((hash) => ({ hash, issued_at: "2026-08-25T12:00:00Z" })),
    }),
  };
}

function basic(user, pass) {
  return "Basic " + Buffer.from(`${user}:${pass}`).toString("base64");
}

async function call(env, path, { auth, headers = {} } = {}) {
  const waits = [];
  const request = new Request("https://get.elitesip.vip/" + path, {
    headers: auth ? { ...headers, Authorization: auth } : headers,
  });
  const response = await worker.fetch(request, env, {
    waitUntil: (p) => waits.push(p),
  });
  await Promise.all(waits);
  return response;
}

function env(objects) {
  return { BUCKET: bucket(objects), AUTH_USER: USER, AUTH_PASS: PASS };
}

const shared = basic(USER, PASS);
const mine = basic(MACHINE, CHANNEL_KEY);

/* ------------------------------------------------------------- доступ */

test("общая пара из бандла не открывает предустановки", async () => {
  const e = env({ "presets/current.json": { body: "{}" } });
  const response = await call(e, "presets/current.json", { auth: shared });

  // Ровно это и покупает разделение: уволенный с копией .app качает выпуски и
  // не качает настройки конторы.
  assert.equal(response.status, 401);
});

test("помашинный ключ открывает предустановки и оставляет отметку", async () => {
  const e = env({
    "presets/current.json": { body: '{"payload":"…"}' },
    ["machines/" + MACHINE]: machineRecord([sha256hex(CHANNEL_KEY)]),
  });

  const response = await call(e, "presets/current.json", {
    auth: mine,
    headers: { "x-elitesip-app": "0.1.28", "x-elitesip-revision": "12" },
  });
  assert.equal(response.status, 200);

  const seen = JSON.parse(e.BUCKET.objects.get("seen/" + MACHINE).body);
  assert.equal(seen.installation_id, MACHINE);
  assert.equal(seen.app_version, "0.1.28");
  assert.equal(seen.preset_revision, 12);
});

test("чужой ключ не подходит, свой старый — подходит", async () => {
  const previous = sha256hex("b".repeat(64));
  const e = env({
    "presets/current.json": { body: "{}" },
    ["machines/" + MACHINE]: machineRecord([sha256hex(CHANNEL_KEY), previous]),
  });

  // При перепрошивке действуют оба: машина ещё не забрала новый пакет, но
  // работать обязана.
  assert.equal((await call(e, "presets/current.json", { auth: mine })).status, 200);
  assert.equal(
    (await call(e, "presets/current.json", { auth: basic(MACHINE, "b".repeat(64)) })).status,
    200
  );
  assert.equal(
    (await call(e, "presets/current.json", { auth: basic(MACHINE, "c".repeat(64)) })).status,
    401
  );
});

test("машина не читает чужой доступ", async () => {
  const e = env({
    ["machines/" + MACHINE]: machineRecord([sha256hex(CHANNEL_KEY)]),
    ["access/" + MACHINE]: { body: '{"admin_password":"своё"}' },
    "access/0000000000000000": { body: '{"admin_password":"чужое"}' },
  });

  assert.equal((await call(e, "access/" + MACHINE, { auth: mine })).status, 200);
  // Иначе разделение доступа стало бы мнимым: пароль техподдержки прочитал бы
  // любой, у кого есть действующий ключ.
  assert.equal((await call(e, "access/0000000000000000", { auth: mine })).status, 404);
});

test("служебные приставки не раздаются никому", async () => {
  const e = env({
    ["machines/" + MACHINE]: machineRecord([sha256hex(CHANNEL_KEY)]),
    ["seen/" + MACHINE]: { body: "{}" },
    "taken/deadbeef": { body: "{}" },
  });

  for (const path of ["machines/" + MACHINE, "seen/" + MACHINE, "taken/deadbeef"]) {
    assert.equal((await call(e, path, { auth: shared })).status, 404, path);
    assert.equal((await call(e, path, { auth: mine })).status, 404, path);
  }
});

/* -------------------------------------------------------- отзыв и сброс */

test("отсутствие отзыва — это 404, а не сброс", async () => {
  const e = env({ ["machines/" + MACHINE]: machineRecord([sha256hex(CHANNEL_KEY)]) });
  const response = await call(e, "revoked/" + MACHINE, { auth: mine });

  // Отсутствие ответа никогда не означает отзыв: иначе опечатка в правиле
  // Cloudflare стирала бы все тридцать машин разом.
  assert.equal(response.status, 404);
});

test("выложенный отзыв отдаётся своей машине", async () => {
  const e = env({
    ["machines/" + MACHINE]: machineRecord([sha256hex(CHANNEL_KEY)]),
    ["revoked/" + MACHINE]: { body: '{"payload":"…","signature":"…"}' },
  });
  const response = await call(e, "revoked/" + MACHINE, { auth: mine });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
});

/* ------------------------------------------------------------ активация */

test("пакет отдаётся один раз, второй запрос получает 410", async () => {
  const e = env({ "activations/deadbeef": { body: "пакет" } });

  const first = await call(e, "activations/deadbeef", { auth: shared });
  assert.equal(first.status, 200);

  const second = await call(e, "activations/deadbeef", { auth: shared });
  assert.equal(second.status, 410);
});

test("отданный пакет отмечается delivered, промах — нет", async () => {
  const e = env({ "activations/deadbeef": { body: "пакет" } });

  await call(e, "activations/deadbeef", { auth: shared });
  const taken = JSON.parse(e.BUCKET.objects.get("taken/deadbeef").body);
  assert.equal(taken.delivered, true);

  // Промах по несуществующему адресу тоже оставляет отметку — Worker столбит
  // до того, как выяснит, что отдавать нечего. Панель обязана отличить одно от
  // другого, иначе опоздавший сотрудник числился бы настроенным.
  await call(e, "activations/nosuchpackage", { auth: shared });
  const miss = JSON.parse(e.BUCKET.objects.get("taken/nosuchpackage").body);
  assert.equal(miss.delivered, false);
});

test("пакет старше двух суток не отдаётся", async () => {
  const old = new Date(Date.now() - 49 * 60 * 60 * 1000);
  const e = env({ "activations/deadbeef": { body: "пакет", uploaded: old } });

  const response = await call(e, "activations/deadbeef", { auth: shared });
  assert.equal(response.status, 410);

  const taken = JSON.parse(e.BUCKET.objects.get("taken/deadbeef").body);
  assert.equal(taken.delivered, false, "просроченный пакет не должен считаться выданным");
});

test("пакет не кэшируется", async () => {
  const e = env({ "activations/deadbeef": { body: "пакет" } });
  const response = await call(e, "activations/deadbeef", { auth: shared });

  // Закэшированная копия сделала бы одноразовость бессмысленной.
  assert.equal(response.headers.get("Cache-Control"), "no-store");
});

/* ------------------------------------------------------------ обновления */

test("выпуски по-прежнему на общей паре", async () => {
  const e = env({ "appcast-arm64.xml": { body: "<rss/>" } });

  assert.equal((await call(e, "appcast-arm64.xml")).status, 401);
  const response = await call(e, "appcast-arm64.xml", { auth: shared });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "application/xml; charset=utf-8");
});
