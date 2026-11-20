import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {DatabaseSync} from "node:sqlite";
import test from "node:test";
import worker from "./worker.mjs";

const schema = readFileSync(new URL("./schema.sql", import.meta.url), "utf8").trim();
const origin = "https://pilot.example";
const fixtureKey = "fixture-value-for-isolated-tests";
const goodReply = () => Response.json({choices: [{message: {content: " Ответ. "}}]});

function database(t, migrate = true) {
    const sqlite = new DatabaseSync(":memory:");
    t.after(() => sqlite.close());
    if (migrate) sqlite.exec(schema);
    const DB = {
        prepare(sql) {
            function statement(values) {
                return {
                    bind: (...args) => statement(args),
                    async run() {
                        const params = Object.fromEntries(values.map((value, i) => ["?" + (i + 1), value]));
                        const {changes} = sqlite.prepare(sql).run(params);
                        return {success: true, meta: {changes}};
                    },
                };
            }
            return statement([]);
        }
    };
    return {env: {DB, OPENAI_API_KEY: fixtureKey}, sqlite};
}

function request(payload = {message: "Хочу подготовить вопрос врачу."}, ip = "192.0.2.1", headers = {}) {
    return new Request(origin + "/v1/chat", {
        method: "POST",
        headers: {"Content-Type": "application/json", ...(ip ? {"CF-Connecting-IP": ip} : {}), ...headers},
        body: JSON.stringify(payload),
    });
}

const spent = sqlite => sqlite.prepare("SELECT count(*) AS n FROM pilot_chat_reservations").get().n;

test("native chat contract, lazy migration, data minimization and pinned provider", async t => {
    const {env, sqlite} = database(t, false);
    const payload = {
        history: [{role: "user", content: "Раньше"}, {role: "assistant", content: "Ответ ранее"}],
        message: " Сейчас ",
    };
    const fetcher = t.mock.method(globalThis, "fetch", async (url, options) => {
        assert.equal(spent(sqlite), 1, "reserve before sending content");
        assert.equal(url, "https://api.openai.com/v1/chat/completions");
        assert.deepEqual(options.headers, {Authorization: "Bearer " + fixtureKey, "Content-Type": "application/json"});
        assert.equal(options.redirect, "manual");
        assert.ok(options.signal instanceof AbortSignal);
        const body = JSON.parse(options.body);
        assert.deepEqual(Object.keys(body).sort(), ["max_completion_tokens", "messages", "model", "store"]);
        assert.equal(body.model, "gpt-4.1-mini");
        assert.equal(body.max_completion_tokens, 300);
        assert.equal(body.store, false);
        assert.equal(body.messages[0].role, "system");
        assert.deepEqual(body.messages.slice(1), [...payload.history, {role: "user", content: "Сейчас"}]);
        return goodReply();
    });
    const response = await worker.fetch(request(payload), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.deepEqual(await response.json(), {reply: "Ответ."});
    assert.equal(fetcher.mock.callCount(), 1);
    const row = sqlite.prepare("SELECT * FROM pilot_chat_reservations").get();
    assert.deepEqual(Object.keys(row), ["day", "client_tag"]);
    assert.match(row.client_tag, /^[0-9a-f]{64}$/);
    assert.match(row.day, /^\d{4}-\d{2}-\d{2}$/);
    const effective = sqlite.prepare("SELECT sql FROM sqlite_schema WHERE name = 'pilot_chat_reservations'").get().sql;
    assert.equal(effective, schema.replace(" IF NOT EXISTS", "").replace(/;$/, ""));
});

test("untrusted schema fields and oversized turns are rejected before quota or inference", async t => {
    const {env, sqlite} = database(t);
    const upstream = t.mock.method(globalThis, "fetch", goodReply);
    const message = "тест";
    for (const payload of [
        [], null, {}, {message: "   "}, {message: 12}, {message, model: "other"}, {message, url: origin},
        {message, history: null}, {message, history: Array(7).fill({role: "user", content: "a"})},
        ...["system", "developer", "tool", "other"].map(role => ({message, history: [{role, content: "a"}]})),
        {message, history: [{role: "user", content: ""}]}, {message, history: [{role: "user", content: "a", name: "override"}]},
        {message: "🚀".repeat(4001)},
    ]) assert.equal((await worker.fetch(request(payload), env)).status, 400);
    assert.equal((await worker.fetch(request({message}, null, {"Content-Type": "text/plain"}), env)).status, 415);
    const malformed = new Request(origin + "/v1/chat", {
        method: "POST", headers: {"Content-Type": "application/json"}, body: "{"
    });
    assert.equal((await worker.fetch(malformed, env)).status, 400);
    assert.equal(spent(sqlite), 0);
    assert.equal(upstream.mock.callCount(), 0);
});

test("enforces the actual streamed byte count even with a false Content-Length", async t => {
    const {env, sqlite} = database(t);
    const upstream = t.mock.method(globalThis, "fetch", goodReply);
    let cancelled = false;
    const stream = new ReadableStream({
        pull(controller) { controller.enqueue(new Uint8Array(32769)); },
        cancel() { cancelled = true; },
    });
    const oversized = new Request(origin + "/v1/chat", {
        method: "POST", headers: {"Content-Type": "application/json", "Content-Length": "4"},
        body: stream, duplex: "half",
    });
    assert.equal((await worker.fetch(oversized, env)).status, 413);
    assert.ok(cancelled);
    assert.equal(spent(sqlite), 0);
    assert.equal(upstream.mock.callCount(), 0);
});

test("competing requests using one IP share a hard cap across concurrent cold starts", async t => {
    const {env, sqlite} = database(t, false);
    const fetcher = t.mock.method(globalThis, "fetch", goodReply);
    const results = await Promise.all(Array.from({length: 35}, (_, n) =>
        worker.fetch(request(undefined, "192.0.2.2", {"X-Forwarded-For": "192.0.2." + n}), env)));
    assert.equal(results.filter(r => r.status === 200).length, 12);
    assert.equal(results.filter(r => r.status === 429).length, 23);
    assert.equal(spent(sqlite), 12);
    assert.equal(fetcher.mock.callCount(), 12);
});

test("global daily and permanent trial budgets cap different clients", async t => {
    const {env, sqlite} = database(t);
    const fetcher = t.mock.method(globalThis, "fetch", goodReply);
    const run = async n => Promise.all(Array.from({length: n}, (_, i) => worker.fetch(request(undefined, "198.51.100." + i), env)));
    assert.equal((await run(70)).filter(r => r.status === 200).length, 60);
    assert.equal(spent(sqlite), 60);
    // Existing reservations from a prior UTC date still consume the trial budget.
    sqlite.exec("UPDATE pilot_chat_reservations SET day = '2000-01-01'");
    const seed = sqlite.prepare("INSERT INTO pilot_chat_reservations VALUES ('2000-01-01', 'old')");
    for (let i = 0; i < 185; i++) seed.run();
    const responses = await run(20);
    assert.equal(responses.filter(r => r.status === 200).length, 5);
    assert.equal(responses.filter(r => r.status === 429).length, 15);
    assert.equal(spent(sqlite), 250);
    assert.equal(fetcher.mock.callCount(), 65);
});

test("upstream failures spend once and keep the provider's diagnostics private", async t => {
    const {env, sqlite} = database(t);
    const errors = [
        () => Response.json({error: {message: "sensitive provider debug"}}, {status: 401}),
        () => Response.json({choices: []}),
        () => new Response("broken json"),
        () => { throw new Error("sensitive network debug"); },
    ];
    const fetcher = t.mock.method(globalThis, "fetch", () => errors.shift()());
    for (const status of [503, 502, 503, 503]) {
        const res = await worker.fetch(request(), env);
        assert.equal(res.status, status);
        assert.doesNotMatch(await res.text(), /sensitive/);
    }
    assert.equal(spent(sqlite), 4);
    assert.equal(fetcher.mock.callCount(), 4);
});

test("fetch deadline aborts a stalled provider and keeps the reservation", async t => {
    const {env, sqlite} = database(t);
    let trigger;
    const timeout = t.mock.method(globalThis, "setTimeout", callback => { trigger = callback; return 1; });
    const clear = t.mock.method(globalThis, "clearTimeout", () => {});
    t.mock.method(globalThis, "fetch", async (_url, {signal}) => {
        const pending = new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason)));
        trigger();
        return pending;
    });
    assert.equal((await worker.fetch(request(), env)).status, 503);
    assert.equal(timeout.mock.calls[0].arguments[1], 20_000);
    assert.equal(clear.mock.callCount(), 1);
    assert.equal(spent(sqlite), 1);
});

test("missing configuration or unavailable quota storage never invokes inference", async t => {
    const {env, sqlite} = database(t);
    const fetcher = t.mock.method(globalThis, "fetch", goodReply);
    for (const configuration of [
        {}, {...env, OPENAI_API_KEY: " "}, {...env, DB: undefined},
        {...env, DB: {prepare() { throw new Error("unavailable"); }}},
    ]) assert.equal((await worker.fetch(request(), configuration)).status, 503);
    assert.equal(fetcher.mock.callCount(), 0);
    assert.equal(spent(sqlite), 0);
});

test("health, unsupported methods and unrelated paths do not open the database or call OpenAI", async t => {
    const fetcher = t.mock.method(globalThis, "fetch", goodReply);
    const health = await worker.fetch(new Request(origin + "/health"), {});
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), {ok: true});
    const wrongMethod = await worker.fetch(new Request(origin + "/v1/chat"), {});
    assert.equal(wrongMethod.status, 405);
    assert.equal(wrongMethod.headers.get("allow"), "POST");
    assert.equal((await worker.fetch(new Request(origin + "/elsewhere"), {})).status, 404);
    assert.equal(fetcher.mock.callCount(), 0);
});
