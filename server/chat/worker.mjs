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

const CHAT_TABLE = "pilot_chat_reservations";
const VOICE_TABLE = "pilot_transcription_reservations";
const AUDIO_LIMIT = 2 * 1024 * 1024;
const AUDIO_SECONDS = 125;

// Table names come exclusively from these two constants.
const createTable = table => `CREATE TABLE IF NOT EXISTS ${table} (
    day TEXT NOT NULL,
    client_tag TEXT NOT NULL
);`;

// A single write both checks and spends capacity. Reservations survive upstream errors.
const reservationSQL = table => `INSERT INTO ${table} (day, client_tag)
SELECT ?1, ?2
WHERE (SELECT COUNT(*) FROM ${table}) < ?3
  AND (SELECT COUNT(*) FROM ${table} WHERE day = ?1) < ?4
  AND (SELECT COUNT(*) FROM ${table} WHERE day = ?1 AND client_tag = ?2) < ?5`;

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

async function reserve(request, env, table = CHAT_TABLE) {
    const day = new Date().toISOString().slice(0, 10);
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey("raw", encoder.encode(env.OPENAI_API_KEY),
        {name: "HMAC", hash: "SHA-256"}, false, ["sign"]);
    // Cloudflare supplies the source header. Requests without it share one bucket.
    const source = request.headers.get("CF-Connecting-IP") || "unknown";
    const digest = await crypto.subtle.sign("HMAC", key, encoder.encode("pilot-chat/v1|" + day + "|" + source));
    const tag = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
    const insert = () => env.DB.prepare(reservationSQL(table)).bind(day, tag, TRIAL_LIMIT, DAILY_LIMIT, CLIENT_DAILY_LIMIT).run();
    let result;
    try {
        result = await insert();
    } catch (error) {
        const missing = "no such table: " + table;
        if (![error?.message, error?.cause?.message].some(message => message?.includes(missing))) throw error;
        await env.DB.prepare(createTable(table)).run();
        result = await insert();
    }
    if (!result.success || ![0, 1].includes(result.meta?.changes)) throw new Error("reservation_failed");
    return result.meta.changes === 1;
}

async function readAudio(request) {
    if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "audio/mp4") {
        throw new InputError(415, "audio_mp4_required");
    }
    if (Number(request.headers.get("content-length")) > AUDIO_LIMIT) throw new InputError(413, "audio_too_large");
    if (!request.body) throw new InputError(400, "invalid_audio");
    const reader = request.body.getReader();
    let bytes = new Uint8Array(0);
    let length = 0;
    try {
        for (;;) {
            const {value, done} = await reader.read();
            if (done) break;
            const needed = length + value.byteLength;
            if (needed > AUDIO_LIMIT) {
                void reader.cancel().catch(() => {});
                throw new InputError(413, "audio_too_large");
            }
            if (needed > bytes.length) {
                const grown = new Uint8Array(Math.min(AUDIO_LIMIT, Math.max(8192, needed, 2 * bytes.length)));
                grown.set(bytes);
                bytes = grown;
            }
            bytes.set(value, length);
            length = needed;
        }
    } finally {
        reader.releaseLock();
    }
    return bytes.subarray(0, length);
}

// Read finalized, single-audio-track M4A files as written by AVAudioRecorder.
// Check the media header and sample timing table, including AAC encoder padding.
function validateRecording(bytes) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const invalid = () => { throw new InputError(400, "invalid_audio"); };
    const fourCC = i => String.fromCharCode(...bytes.subarray(i, i + 4));
    function boxes(start, end) {
        const entries = [];
        while (start < end) {
            if (end - start < 8 || entries.length >= 512) invalid();
            let size = view.getUint32(start);
            let header = 8;
            if (size === 1) {
                if (end - start < 16) invalid();
                size = Number(view.getBigUint64(start + 8));
                header = 16;
            } else if (size === 0) size = end - start;
            if (size < header || size > end - start) invalid();
            entries.push({type: fourCC(start + 4), start: start + header, end: start + size});
            start += size;
        }
        return entries;
    }
    function one(entries, type, minSize = 0) {
        const found = entries.filter(box => box.type === type);
        if (found.length !== 1 || found[0].end - found[0].start < minSize) invalid();
        return found[0];
    }
    function children(box) { return boxes(box.start, box.end); }
    function duration(units, scale) {
        if (!scale || !units) invalid();
        if (units > scale * AUDIO_SECONDS) throw new InputError(413, "audio_too_long");
    }

    const top = boxes(0, bytes.byteLength);
    one(top, "ftyp", 8);
    one(top, "mdat", 1);
    if (top.some(box => box.type === "moof")) invalid();
    const track = one(children(one(top, "moov")), "trak");
    const media = children(one(children(track), "mdia"));
    const handler = one(media, "hdlr", 12);
    if (fourCC(handler.start + 8) !== "soun") invalid();
    const header = one(media, "mdhd", 20);
    const version = bytes[header.start];
    if (version > 1 || (version === 1 && header.end - header.start < 32)) invalid();
    const scale = view.getUint32(header.start + (version === 1 ? 20 : 12));
    const units = version === 1 ? Number(view.getBigUint64(header.start + 24)) : view.getUint32(header.start + 16);
    duration(units, scale);

    const samples = children(one(children(one(media, "minf")), "stbl"));
    const descriptions = one(samples, "stsd", 8);
    if (view.getUint32(descriptions.start + 4) !== 1) invalid();
    const aac = one(boxes(descriptions.start + 8, descriptions.end), "mp4a", 28);
    const rate = view.getUint16(aac.start + 24);
    const timing = one(samples, "stts", 8);
    const rows = view.getUint32(timing.start + 4);
    if (rows === 0 || rows * 8 !== timing.end - timing.start - 8) invalid();
    let frames = 0;
    let ticks = 0;
    for (let pos = timing.start + 8; pos < timing.end; pos += 8) {
        const count = view.getUint32(pos);
        const delta = view.getUint32(pos + 4);
        if (!count || !delta) invalid();
        frames += count;
        ticks += count * delta;
        duration(ticks, scale);
    }
    const sizes = one(samples, "stsz", 12);
    const sampleCount = view.getUint32(sizes.start + 8);
    if (sampleCount !== frames) invalid();
    if (view.getUint32(sizes.start + 4) === 0 && sizes.end - sizes.start - 12 !== 4 * sampleCount) invalid();
    // AAC-LC uses 1024 PCM samples per access unit. This independent ceiling
    // also bounds recordings whose declared timeline has been compressed.
    duration(frames * 1024, rate);
}

async function transcribe(request, env) {
    if (request.method !== "POST") return json({error: "method_not_allowed"}, 405, {Allow: "POST"});
    let bytes;
    try {
        bytes = await readAudio(request);
        validateRecording(bytes);
    } catch (error) {
        return error instanceof InputError ? json({error: error.message}, error.status) : json({error: "invalid_audio"}, 400);
    }
    if (!env.OPENAI_API_KEY?.trim() || !env.DB) return json({error: "service_unavailable"}, 503);
    try {
        if (!await reserve(request, env, VOICE_TABLE)) return json({error: "pilot_limit"}, 429);
    } catch {
        return json({error: "service_unavailable"}, 503);
    }

    const form = new FormData();
    form.append("model", "gpt-transcribe");
    form.append("file", new Blob([bytes], {type: "audio/mp4"}), "voice.m4a");
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 45_000);
    try {
        const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
            method: "POST",
            headers: {Authorization: "Bearer " + env.OPENAI_API_KEY},
            body: form,
            redirect: "manual",
            signal: controller.signal,
        });
        if (!response.ok) {
            await response.body?.cancel();
            return json({error: "provider_unavailable"}, 503);
        }
        const transcript = (await response.json())?.text;
        if (typeof transcript !== "string") return json({error: "invalid_provider_reply"}, 502);
        const text = transcript.trim();
        if (!text) return json({error: "no_speech"}, 422);
        if (Array.from(text).length > TURN_LIMIT) return json({error: "transcript_too_long"}, 422);
        return json({text});
    } catch {
        return json({error: "provider_unavailable"}, 503);
    } finally {
        clearTimeout(timer);
    }
}

export default {
    async fetch(request, env) {
        const path = new URL(request.url).pathname;
        if (path === "/health" && request.method === "GET") return json({ok: true});
        if (path === "/v1/transcribe") return transcribe(request, env);
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

        let phase = "request";
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 20_000);
        try {
            const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
                method: "POST",
                headers: {Authorization: "Bearer " + env.OPENAI_API_KEY, "Content-Type": "application/json"},
                body: JSON.stringify({model: "gpt-4.1-mini", messages, max_completion_tokens: 300, store: false}),
                redirect: "manual",
                signal: controller.signal,
            });
            if (!upstream.ok) {
                // Log only the HTTP status and a known machine code. Provider messages
                // can contain submitted text or credential fragments.
                const detail = await upstream.json().catch(() => null);
                const known = ["invalid_api_key", "insufficient_quota", "model_not_found",
                    "rate_limit_exceeded", "unsupported_country_region_territory"];
                const code = detail?.error?.code;
                const category = known.includes(code) ? code : "other";
                console.warn("chat_provider_failure", upstream.status, category);
                return json({error: "provider_unavailable", status: upstream.status, category}, 503);
            }
            phase = "decode";
            const reply = (await upstream.json()).choices?.[0]?.message?.content;
            if (typeof reply !== "string" || !reply.trim()) return json({error: "invalid_provider_reply"}, 502);
            return json({reply: Array.from(reply.trim()).slice(0, TURN_LIMIT).join("")});
        } catch (error) {
            const category = controller.signal.aborted ? "timeout" : phase === "decode" ? "invalid_response" : "transport";
            console.warn("chat_provider_failure", category);
            return json({error: "provider_unavailable", category}, 503);
        } finally {
            clearTimeout(timer);
        }
    }
};
