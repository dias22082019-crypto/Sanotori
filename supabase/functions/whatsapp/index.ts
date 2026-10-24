// Sanatorium OS · Edge Function «whatsapp»: отправка сообщений и проверка подключения через официальный
// WhatsApp Cloud API (Meta Graph API). Один файл без внешних зависимостей, чтобы его можно было вставить
// в редактор Edge Functions в панели Supabase.
//
// Безопасность:
//  * права сотрудника проверяет база: функция вызывает RPC с его токеном (whatsapp_queue_message, whatsapp_begin_check);
//  * токен Meta читается из Vault только ключом service_role и никогда не возвращается в ответе;
//  * статус «отправлено» записывается только после ответа Meta с идентификатором сообщения.
//
// Развёртывание: функция «whatsapp», проверку JWT в настройках функции отключить (Verify JWT = off):
// пользователь проверяется базой по его токену, а новые ключи Supabase не являются JWT.

export const GRAPH_API_VERSION = "v25.0";

type Json = Record<string, unknown>;
type DenoLike = { env: { get(name: string): string | undefined }; serve(handler: (req: Request) => Promise<Response>): unknown };

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** Тело запроса к Meta для текста или утверждённого шаблона */
export function buildSendPayload(claim: { to: string; kind: string; body?: string | null; template_name?: string | null; template_lang?: string | null }): Json {
  if (claim.kind === "template") {
    return {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: claim.to,
      type: "template",
      template: { name: claim.template_name, language: { code: claim.template_lang } },
    };
  }
  return { messaging_product: "whatsapp", recipient_type: "individual", to: claim.to, type: "text", text: { preview_url: false, body: claim.body ?? "" } };
}

/** Понятный текст ошибки Meta: «(#131047) Re-engagement message» и т. п.; без токенов и лишних данных */
export function describeGraphError(status: number, body: unknown): string {
  const e = (body as { error?: { code?: number; message?: string; error_data?: { details?: string } } } | null)?.error;
  if (!e) return `HTTP ${status}`;
  const details = e.error_data?.details ? `: ${e.error_data.details}` : "";
  return `(#${e.code ?? status}) ${e.message ?? "error"}${details}`.slice(0, 500);
}

/** Идентификатор отправленного сообщения из ответа Meta (messages[0].id) */
export function sentMessageId(body: unknown): string | null {
  const id = (body as { messages?: { id?: string }[] } | null)?.messages?.[0]?.id;
  return typeof id === "string" && id.length > 0 ? id : null;
}

function env(deno: DenoLike) {
  const url = deno.env.get("SUPABASE_URL") ?? "";
  const pick = (name: string) => {
    try {
      return (JSON.parse(deno.env.get(name) ?? "{}") as Record<string, string>).default;
    } catch {
      return undefined;
    }
  };
  // новые ключи (sb_secret_…) или прежний service_role
  const serviceKey = pick("SUPABASE_SECRET_KEYS") ?? deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const publicKey = pick("SUPABASE_PUBLISHABLE_KEYS") ?? deno.env.get("SUPABASE_ANON_KEY") ?? "";
  return { url, serviceKey, publicKey };
}

/** Вызов RPC PostgREST: от имени сотрудника (его JWT) или сервиса (ключ service_role / secret) */
async function rpc(base: string, fn: string, args: Json, auth: { apikey: string; bearer?: string }) {
  const headers: Record<string, string> = { "Content-Type": "application/json", apikey: auth.apikey };
  if (auth.bearer) headers.Authorization = `Bearer ${auth.bearer}`;
  else if (auth.apikey.split(".").length === 3) headers.Authorization = `Bearer ${auth.apikey}`; // прежний ключ — JWT
  const res = await fetch(`${base}/rest/v1/rpc/${fn}`, { method: "POST", headers, body: JSON.stringify(args) });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  return { ok: res.ok, status: res.status, data };
}

const json = (status: number, body: Json) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

export async function handle(req: Request, deno: DenoLike): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  const { url, serviceKey, publicKey } = env(deno);
  const userJwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!url || !serviceKey || !userJwt) return json(401, { error: "unauthorized" });
  const asUser = { apikey: req.headers.get("apikey") ?? publicKey, bearer: userJwt };
  const asService = { apikey: serviceKey };

  let input: Json;
  try {
    input = await req.json();
  } catch {
    return json(400, { error: "invalid json" });
  }

  if (input.action === "check") {
    const begin = await rpc(url, "whatsapp_begin_check", { p_tenant: input.tenant }, asUser);
    if (!begin.ok) return json(begin.status === 401 ? 401 : 403, { error: begin.data?.message ?? "forbidden" });
    const cred = await rpc(url, "whatsapp_credentials", { p_tenant: input.tenant }, asService);
    if (!cred.ok || !cred.data?.access_token) return json(500, { error: "credentials unavailable" });
    const res = await fetch(
      `https://graph.facebook.com/${GRAPH_API_VERSION}/${cred.data.phone_number_id}?fields=display_phone_number,verified_name`,
      { headers: { Authorization: `Bearer ${cred.data.access_token}` } },
    );
    const body = await res.json().catch(() => null);
    const ok = res.ok && typeof body?.display_phone_number === "string";
    await rpc(url, "whatsapp_set_check_result", {
      p_tenant: input.tenant, p_ok: ok,
      p_display_phone: ok ? body.display_phone_number : null, p_verified_name: ok ? body.verified_name ?? null : null,
      p_error: ok ? null : describeGraphError(res.status, body),
    }, asService);
    return json(200, ok ? { ok, display_phone: body.display_phone_number, verified_name: body.verified_name ?? null }
                        : { ok, error: describeGraphError(res.status, body) });
  }

  if (input.action === "send") {
    // 1. права, тариф, окно 24 часа и запись «в очереди» — в базе, от имени сотрудника
    const queued = await rpc(url, "whatsapp_queue_message", {
      p_tenant: input.tenant, p_phone: input.phone, p_text: input.text ?? null,
      p_template_name: input.template_name ?? null, p_template_lang: input.template_lang ?? null, p_booking_id: input.booking_id ?? null,
    }, asUser);
    if (!queued.ok) return json(queued.status === 401 ? 401 : 400, { error: queued.data?.message ?? "rejected" });
    // 2. забрать сообщение с реквизитами (один раз) и отправить в Meta
    const claim = await rpc(url, "whatsapp_claim_message", { p_message_id: queued.data }, asService);
    if (!claim.ok) return json(500, { error: "claim failed", message_id: queued.data });
    if (claim.data?.error) return json(409, { error: claim.data.error, message_id: queued.data });
    let waId: string | null = null;
    let error: string | null = null;
    try {
      const res = await fetch(`https://graph.facebook.com/${GRAPH_API_VERSION}/${claim.data.phone_number_id}/messages`, {
        method: "POST",
        headers: { Authorization: `Bearer ${claim.data.access_token}`, "Content-Type": "application/json" },
        body: JSON.stringify(buildSendPayload(claim.data)),
      });
      const body = await res.json().catch(() => null);
      waId = res.ok ? sentMessageId(body) : null;
      if (!waId) error = describeGraphError(res.status, body);
    } catch (e) {
      error = `network: ${(e as Error).message}`.slice(0, 500);
    }
    // 3. записать результат: «отправлено» только с идентификатором от Meta
    await rpc(url, "whatsapp_finish_message", { p_message_id: queued.data, p_wa_message_id: waId, p_error: error }, asService);
    return json(200, { message_id: queued.data, status: waId ? "sent" : "failed", error });
  }

  return json(400, { error: "unknown action" });
}

const deno = (globalThis as unknown as { Deno?: DenoLike }).Deno;
if (deno?.serve) deno.serve((req) => handle(req, deno));
