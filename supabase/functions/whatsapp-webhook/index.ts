// Sanatorium OS · Edge Function «whatsapp-webhook»: приём вебхуков WhatsApp Cloud API от Meta.
// Один файл без внешних зависимостей (можно вставить в редактор Edge Functions в панели Supabase).
//
//  * GET — подтверждение подписки: hub.mode=subscribe и hub.verify_token санатория → ответ hub.challenge;
//  * POST — события: подпись X-Hub-Signature-256 (HMAC-SHA256 сырого тела ключом App Secret) проверяется для
//    каждого номера; без верной подписи событие не сохраняется. Санаторий определяется по phone_number_id.
//
// Развёртывание: функция «whatsapp-webhook», проверку JWT отключить (Verify JWT = off): Meta не передаёт токен Supabase.
// Адрес для Meta: https://<project>.supabase.co/functions/v1/whatsapp-webhook

type Json = Record<string, unknown>;
type DenoLike = { env: { get(name: string): string | undefined }; serve(handler: (req: Request) => Promise<Response>): unknown };

/** HMAC-SHA256 в hex */
async function hmacHex(secret: string, payload: Uint8Array<ArrayBuffer>): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, payload));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Сравнение без утечки по времени */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Проверка заголовка «sha256=<hex>» по сырому телу запроса */
export async function verifySignature(rawBody: Uint8Array<ArrayBuffer>, header: string | null, appSecret: string): Promise<boolean> {
  const m = /^sha256=([0-9a-f]{64})$/i.exec((header ?? "").trim());
  if (!m || !appSecret) return false;
  return safeEqual((await hmacHex(appSecret, rawBody)).toLowerCase(), m[1].toLowerCase());
}

/** Изменения с полем messages, сгруппированные по номеру (phone_number_id) */
export function messageChanges(payload: unknown): { phoneNumberId: string; value: Json }[] {
  const out: { phoneNumberId: string; value: Json }[] = [];
  const entries = (payload as { object?: string; entry?: unknown[] } | null)?.entry;
  if ((payload as { object?: string } | null)?.object !== "whatsapp_business_account" || !Array.isArray(entries)) return out;
  for (const entry of entries) {
    for (const change of ((entry as { changes?: unknown[] })?.changes ?? []) as { field?: string; value?: Json }[]) {
      const id = (change?.value?.metadata as { phone_number_id?: unknown } | undefined)?.phone_number_id;
      if (change?.field === "messages" && typeof id === "string" && /^[0-9]{5,25}$/.test(id) && change.value) {
        out.push({ phoneNumberId: id, value: change.value });
      }
    }
  }
  return out;
}

function serviceAuth(deno: DenoLike) {
  let key: string | undefined;
  try {
    key = (JSON.parse(deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}") as Record<string, string>).default;
  } catch {
    key = undefined;
  }
  key = key ?? deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const headers: Record<string, string> = { "Content-Type": "application/json", apikey: key };
  if (key.split(".").length === 3) headers.Authorization = `Bearer ${key}`; // прежний ключ — JWT
  return { url: deno.env.get("SUPABASE_URL") ?? "", headers };
}

async function rpc(deno: DenoLike, fn: string, args: Json) {
  const { url, headers } = serviceAuth(deno);
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, { method: "POST", headers, body: JSON.stringify(args) });
  const text = await res.text();
  if (!res.ok) throw new Error(`${fn}: HTTP ${res.status}`);
  return text ? JSON.parse(text) : null;
}

export async function handle(req: Request, deno: DenoLike): Promise<Response> {
  const url = new URL(req.url);

  if (req.method === "GET") {
    const mode = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token") ?? "";
    const challenge = url.searchParams.get("hub.challenge") ?? "";
    if (mode === "subscribe" && token && (await rpc(deno, "whatsapp_verify_token_valid", { p_token: token })) === true) {
      return new Response(challenge, { status: 200, headers: { "Content-Type": "text/plain" } });
    }
    return new Response("forbidden", { status: 403 });
  }

  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const raw = new Uint8Array(await req.arrayBuffer());
  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return new Response("bad request", { status: 400 });
  }
  const signature = req.headers.get("X-Hub-Signature-256");
  const secrets = new Map<string, string | null>();
  let accepted = 0;
  for (const change of messageChanges(payload)) {
    if (!secrets.has(change.phoneNumberId)) {
      secrets.set(change.phoneNumberId, await rpc(deno, "whatsapp_app_secret", { p_phone_number_id: change.phoneNumberId }));
    }
    const secret = secrets.get(change.phoneNumberId);
    // неизвестный номер или неверная подпись — событие не сохраняется
    if (!secret || !(await verifySignature(raw, signature, secret))) continue;
    await rpc(deno, "whatsapp_ingest", { p_phone_number_id: change.phoneNumberId, p_value: change.value });
    accepted++;
  }
  // Meta ждёт 200, иначе повторяет доставку; отклонённые события не повторяем
  return new Response(JSON.stringify({ accepted }), { status: 200, headers: { "Content-Type": "application/json" } });
}

const deno = (globalThis as unknown as { Deno?: DenoLike }).Deno;
if (deno?.serve) deno.serve((req) => handle(req, deno));
