const BODY_LIMIT = 64 * 1024;
const TURN_LIMIT = 4000;
const HISTORY_LIMIT = 6;
const TRIAL_LIMIT = 250;
const DAILY_LIMIT = 60;
const CLIENT_DAILY_LIMIT = 12;

const SYSTEM_PROMPT = `Ты собеседник в русскоязычном приложении «Это ты». Ответь на последнюю реплику живо и конкретно,
учитывая предыдущие реплики этой беседы. При необходимости задай один вопрос. Ответ до трёх предложений.
Помогай человеку сформулировать наблюдение или подготовиться к визиту. Ты видишь только эту беседу.
Не ставь диагнозы, не оценивай состояние здоровья, не назначай анализы, препараты и лечение.
Не утверждай, что видел документы, поставил напоминание, сохранил факт или связался с врачом.
При непосредственной угрозе жизни предложи обратиться в местную экстренную службу.`;

const CREATE_TABLE = `CREATE TABLE IF NOT EXISTS pilot_chat_reservations (
    day TEXT NOT NULL,
    client_tag TEXT NOT NULL
);`;

// A single write both checks and spends capacity. Reservations survive upstream errors.
const RESERVE = `INSERT INTO pilot_chat_reservations (day, client_tag)
SELECT ?1, ?2
WHERE (SELECT COUNT(*) FROM pilot_chat_reservations) < ?3
  AND (SELECT COUNT(*) FROM pilot_chat_reservations WHERE day = ?1) < ?4
  AND (SELECT COUNT(*) FROM pilot_chat_reservations WHERE day = ?1 AND client_tag = ?2) < ?5`;

function json(value, status = 200, headers = {}) {
    return Response.json(value, {status, headers: {"Cache-Control": "no-store", ...headers}});
}

class InputError extends Error {
    constructor(status, message) {
        super(message);
        this.status = status;
    }
}

async function readPayload(request) {
    if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
        throw new InputError(415, "application_json_required");
    }
    if (Number(request.headers.get("content-length")) > BODY_LIMIT) {
        throw new InputError(413, "request_too_large");
    }
    if (!request.body) throw new InputError(400, "invalid_request");
    const reader = request.body.getReader();
    const decoder = new TextDecoder("utf-8", {fatal: true});
    let size = 0;
    let raw = "";
    try {
        for (;;) {
            const {value, done} = await reader.read();
            if (done) break;
            size += value.byteLength;
            if (size > BODY_LIMIT) {
                void reader.cancel().catch(() => {});
                throw new InputError(413, "request_too_large");
            }
            raw += decoder.decode(value, {stream: true});
        }
        return JSON.parse(raw + decoder.decode());
    } catch (error) {
        if (error instanceof InputError) throw error;
        throw new InputError(400, "invalid_json");
    } finally {
        reader.releaseLock();
    }
}

function hasOnlyFields(value, allowed) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
        && Object.keys(value).every(key => allowed.includes(key));
}

function turnText(value) {
    if (typeof value !== "string" || !value.trim() || Array.from(value).length > TURN_LIMIT) {
        throw new InputError(400, "invalid_turn");
    }
    return value.trim();
}

function messagesFor(payload) {
    if (!hasOnlyFields(payload, ["message", "history"])) throw new InputError(400, "invalid_request");
    const message = turnText(payload.message);
    const history = payload.history === undefined ? [] : payload.history;
    if (!Array.isArray(history) || history.length > HISTORY_LIMIT) throw new InputError(400, "invalid_history");
    const turns = history.map(turn => {
        if (!hasOnlyFields(turn, ["role", "content"]) || !["user", "assistant"].includes(turn.role)) {
            throw new InputError(400, "invalid_history");
        }
        return {role: turn.role, content: turnText(turn.content)};
    });
    return [{role: "system", content: SYSTEM_PROMPT}, ...turns, {role: "user", content: message}];
}

async function reserve(request, env) {
    const day = new Date().toISOString().slice(0, 10);
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey("raw", encoder.encode(env.OPENAI_API_KEY),
        {name: "HMAC", hash: "SHA-256"}, false, ["sign"]);
    // Cloudflare supplies the source header. Requests without it share one bucket.
    const source = request.headers.get("CF-Connecting-IP") || "unknown";
    const digest = await crypto.subtle.sign("HMAC", key, encoder.encode("pilot-chat/v1|" + day + "|" + source));
    const tag = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
    const insert = () => env.DB.prepare(RESERVE).bind(day, tag, TRIAL_LIMIT, DAILY_LIMIT, CLIENT_DAILY_LIMIT).run();
    let result;
    try {
        result = await insert();
    } catch (error) {
        const missing = "no such table: pilot_chat_reservations";
        if (![error?.message, error?.cause?.message].some(message => message?.includes(missing))) throw error;
        await env.DB.prepare(CREATE_TABLE).run();
        result = await insert();
    }
    if (!result.success || ![0, 1].includes(result.meta?.changes)) throw new Error("reservation_failed");
    return result.meta.changes === 1;
}

export default {
    async fetch(request, env) {
        const path = new URL(request.url).pathname;
        if (path === "/health" && request.method === "GET") return json({ok: true});
        if (path !== "/v1/chat") return json({error: "not_found"}, 404);
        if (request.method !== "POST") return json({error: "method_not_allowed"}, 405, {Allow: "POST"});
        let messages;
        try {
            messages = messagesFor(await readPayload(request));
        } catch (error) {
            if (error instanceof InputError) return json({error: error.message}, error.status);
            return json({error: "invalid_request"}, 400);
        }
        if (!env.OPENAI_API_KEY?.trim() || !env.DB) return json({error: "service_unavailable"}, 503);
        try {
            if (!await reserve(request, env)) return json({error: "pilot_limit"}, 429);
        } catch {
            return json({error: "service_unavailable"}, 503);
        }

        try {
            const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
                method: "POST",
                headers: {Authorization: "Bearer " + env.OPENAI_API_KEY, "Content-Type": "application/json"},
                body: JSON.stringify({model: "gpt-4.1-mini", messages, max_completion_tokens: 300, store: false}),
                redirect: "error",
                signal: AbortSignal.timeout(20_000),
            });
            if (!upstream.ok) {
                // Log only the HTTP status and a known machine code. Provider messages
                // can contain submitted text or credential fragments.
                const detail = await upstream.json().catch(() => null);
                const known = ["invalid_api_key", "insufficient_quota", "model_not_found",
                    "rate_limit_exceeded", "unsupported_country_region_territory"];
                const code = detail?.error?.code;
                console.warn("chat_provider_failure", upstream.status, known.includes(code) ? code : "other");
                return json({error: "provider_unavailable"}, 503);
            }
            const reply = (await upstream.json()).choices?.[0]?.message?.content;
            if (typeof reply !== "string" || !reply.trim()) return json({error: "invalid_provider_reply"}, 502);
            return json({reply: Array.from(reply.trim()).slice(0, TURN_LIMIT).join("")});
        } catch {
            return json({error: "provider_unavailable"}, 503);
        }
    }
};
