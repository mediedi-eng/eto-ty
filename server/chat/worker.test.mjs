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

// 100 ms of synthetic silence, encoded as mono AAC-LC at 16 kHz by ffmpeg.
const recording = Buffer.from("AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAAAJW1kYXTeAgBMYXZjNjEuMTkuMTAxAAIwQA4BGCAHARggBwAAAwZtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAZAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACMXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAZAAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAGQAAAQAAAEAAAAAAaltZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAD6AAAAKQFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAAFUbWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAEYc3RibAAAAGpzdHNkAAAAAAAAAAEAAABabXA0YQAAAAAAAAABAAAAAAAAAAAAAQAQAAAAAD6AAAAAAAA2ZXNkcwAAAAADgICAJQABAASAgIAXQBUAAAAAALuAAAAFhgWAgIAFFAhW5QAGgICAAQIAAAAgc3R0cwAAAAAAAAACAAAAAgAABAAAAAABAAACQAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAwAAAAEAAAAgc3RzegAAAAAAAAAAAAAAAwAAABUAAAAEAAAABAAAABRzdGNvAAAAAAAAAAEAAAAsAAAAGnNncGQBAAAAcm9sbAAAAAIAAAAB//8AAAAcc2JncAAAAAByb2xsAAAAAQAAAAMAAAABAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2MS43LjEwMw==", "base64");

function voiceRequest(bytes = recording, headers = {}) {
    return new Request(origin + "/v1/transcribe", {
        method: "POST",
        headers: {"Content-Type": "audio/mp4", "CF-Connecting-IP": "192.0.2.1", ...headers},
        body: bytes, duplex: "half",
    });
}

function voiceSpent(db) {
    return db.prepare("SELECT count(*) AS n FROM pilot_transcription_reservations").get().n;
}

test("a real AAC M4A is reserved separately and sent as a named multipart file", async t => {
    const {env, sqlite} = database(t);
    const fetcher = t.mock.method(globalThis, "fetch", async (url, options) => {
        assert.equal(url, "https://api.openai.com/v1/audio/transcriptions");
        assert.equal(voiceSpent(sqlite), 1);
        assert.equal(spent(sqlite), 0);
        assert.deepEqual(options.headers, {Authorization: "Bearer " + fixtureKey});
        assert.equal(options.redirect, "manual");
        assert.equal(options.body.get("model"), "gpt-transcribe");
        assert.deepEqual(options.body.getAll("languages[]"), ["ru"]);
        assert.deepEqual([...options.body.keys()].sort(), ["file", "languages[]", "model"]);
        const file = options.body.get("file");
        assert.equal(file.name, "voice.m4a");
        assert.equal(file.type, "audio/mp4");
        assert.deepEqual(Buffer.from(await file.arrayBuffer()), recording);
        return Response.json({text: " Привет! "});
    });
    const result = await worker.fetch(voiceRequest(), env);
    assert.equal(fetcher.mock.callCount(), 1);
    assert.equal(result.status, 200);
    assert.equal(result.headers.get("cache-control"), "no-store");
    assert.deepEqual(await result.json(), {text: "Привет!"});
    const row = sqlite.prepare("SELECT * FROM pilot_transcription_reservations").get();
    assert.deepEqual(Object.keys(row), ["day", "client_tag"]);
    assert.match(row.client_tag, /^[0-9a-f]{64}$/);
});

test("audio type, container, duration and streamed bytes are checked before quota", async t => {
    const {env, sqlite} = database(t);
    const upstream = t.mock.method(globalThis, "fetch", goodReply);
    const changed = (marker, offset, value) => {
        const audio = Buffer.from(recording);
        const at = audio.indexOf(marker);
        assert.ok(at > 0);
        audio.writeUInt32BE(value, at + offset);
        return audio;
    };
    const requests = [
        [voiceRequest(recording, {"Content-Type": "audio/wav"}), 415],
        [voiceRequest(null), 400],
        [voiceRequest(Buffer.from("not an audio file")), 400],
        [voiceRequest(recording.subarray(0, 40)), 400],
        [voiceRequest(changed("mdhd", 20, 16000 * 126)), 413],
        [voiceRequest(changed("stts", 16, 16000 * 126)), 413],
        [voiceRequest(changed("mp4a", 0, 0x61766331)), 400],
        [voiceRequest(changed("soun", 0, 0x76696465)), 400],
        [voiceRequest(changed("stsz", 12, 2000)), 400],
        [voiceRequest(recording, {"content-length": String(2 * 1024 * 1024 + 1)}), 413],
        [new Request(origin + "/v1/transcribe"), 405],
    ];
    for (const [req, expected] of requests) assert.equal((await worker.fetch(req, env)).status, expected);
    for (const headers of [{}, {"content-length": "1"}]) {
        let cancelled = false;
        const stream = new ReadableStream({
            pull(controller) { controller.enqueue(new Uint8Array(1024 * 1024 + 1)); },
            cancel() { cancelled = true; },
        });
        assert.equal((await worker.fetch(voiceRequest(stream, headers), env)).status, 413);
        assert.ok(cancelled);
    }
    assert.equal(upstream.mock.callCount(), 0);
    assert.equal(sqlite.prepare("SELECT count(*) AS n FROM sqlite_schema WHERE name='pilot_transcription_reservations'").get().n, 0);
});

test("racing uploads spend their own daily and trial quota", async t => {
    const {env, sqlite} = database(t);
    const upstream = t.mock.method(globalThis, "fetch", () => Response.json({text: "да"}));
    const statuses = async (n, distinct = false) => Promise.all(Array.from({length: n}, (_, i) =>
        worker.fetch(voiceRequest(recording, distinct ? {"CF-Connecting-IP": "198.51.100." + i} : {}), env)
            .then(r => r.status)));
    const first = await statuses(20);
    assert.equal(first.filter(n => n === 200).length, 12);
    assert.equal(first.filter(n => n === 429).length, 8);
    const daily = await statuses(60, true);
    assert.equal(daily.filter(n => n === 200).length, 48);
    assert.equal(daily.filter(n => n === 429).length, 12);
    sqlite.exec("UPDATE pilot_transcription_reservations SET day = '2000-01-01'");
    const seed = sqlite.prepare("INSERT INTO pilot_transcription_reservations VALUES ('2000-01-01', 'old')");
    for (let i = 0; i < 189; i++) seed.run();
    const trial = await statuses(5, true);
    assert.equal(trial.filter(n => n === 200).length, 1);
    assert.equal(trial.filter(n => n === 429).length, 4);
    assert.equal(voiceSpent(sqlite), 250);
    assert.equal(spent(sqlite), 0);
    assert.equal(upstream.mock.callCount(), 61);
});

test("transcription reports silence, oversized transcripts and provider failures without disclosing content", async t => {
    const {env, sqlite} = database(t);
    const fixtures = [
        [() => Response.json({text: " "}), 422, "no_speech"],
        [() => Response.json({text: "🚀".repeat(4001)}), 422, "transcript_too_long"],
        [() => Response.json({}), 502, "invalid_provider_reply"],
        [() => Response.json({error: "sensitive provider error"}, {status: 500}), 503, "provider_unavailable"],
        [() => { throw new Error("sensitive transport error"); }, 503, "provider_unavailable"],
    ];
    const upstream = t.mock.method(globalThis, "fetch", () => Response.json({text: "🚀".repeat(4000)}));
    const boundary = await worker.fetch(voiceRequest(), env);
    assert.equal(boundary.status, 200);
    assert.equal((await boundary.json()).text, "🚀".repeat(4000));
    for (const [reply, status, error] of fixtures) {
        upstream.mock.mockImplementation(reply);
        const result = await worker.fetch(voiceRequest(), env);
        assert.equal(result.status, status);
        assert.deepEqual(await result.json(), {error});
    }
    assert.equal(voiceSpent(sqlite), 1 + fixtures.length);
});

test("transcription has a 45-second upstream deadline and fails closed without quota storage or credentials", async t => {
    const {env, sqlite} = database(t);
    let abort;
    const timer = t.mock.method(globalThis, "setTimeout", fn => { abort = fn; return 1; });
    const clear = t.mock.method(globalThis, "clearTimeout", () => {});
    const upstream = t.mock.method(globalThis, "fetch", (_url, {signal}) => {
        const pending = new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason)));
        abort();
        return pending;
    });
    for (const config of [{DB: env.DB}, {...env, DB: {}}, {...env, DB: undefined}]) {
        assert.equal((await worker.fetch(voiceRequest(), config)).status, 503);
    }
    assert.equal(upstream.mock.callCount(), 0);
    assert.equal((await worker.fetch(voiceRequest(), env)).status, 503);
    assert.equal(timer.mock.calls[0].arguments[1], 45_000);
    assert.equal(clear.mock.callCount(), 1);
    assert.equal(voiceSpent(sqlite), 1);
    assert.equal(spent(sqlite), 0);
});
