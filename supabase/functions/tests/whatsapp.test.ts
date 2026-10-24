// @vitest-environment node
// Тесты Edge Functions WhatsApp без сети: запросы к Supabase и Meta подменяются, проверяется логика и безопасность.
import { createHmac } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildSendPayload, describeGraphError, handle as handleSend, sentMessageId } from "../whatsapp/index";
import { handle as handleWebhook, messageChanges, verifySignature } from "../whatsapp-webhook/index";

const ENV: Record<string, string> = {
  SUPABASE_URL: "https://proj.supabase.co",
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_test" }),
  SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_test" }),
};
const deno = { env: { get: (k: string) => ENV[k] }, serve: () => undefined };
const APP_SECRET = "abcdef0123456789abcdef0123456789";
const TOKEN = "EAAG-secret-token-should-never-leak";

type Call = { url: string; init?: RequestInit };
function mockFetch(routes: (url: string, init?: RequestInit) => Response) {
  const calls: Call[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
    calls.push({ url, init });
    return routes(url, init);
  }));
  return calls;
}
const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

afterEach(() => vi.unstubAllGlobals());

const inbound = {
  object: "whatsapp_business_account",
  entry: [{ id: "WABA", changes: [{ field: "messages", value: {
    messaging_product: "whatsapp", metadata: { phone_number_id: "1234567890" },
    messages: [{ from: "77015551010", id: "wamid.IN1", type: "text", text: { body: "Сәлем" } }],
  } }] }],
};

describe("whatsapp helpers", () => {
  it("builds text and template payloads for the Cloud API", () => {
    expect(buildSendPayload({ to: "77015551010", kind: "text", body: "Привет" })).toEqual({
      messaging_product: "whatsapp", recipient_type: "individual", to: "77015551010", type: "text", text: { preview_url: false, body: "Привет" },
    });
    expect(buildSendPayload({ to: "77015551010", kind: "template", template_name: "booking_confirmed", template_lang: "ru" })).toMatchObject({
      type: "template", template: { name: "booking_confirmed", language: { code: "ru" } },
    });
  });
  it("reads Meta errors and message ids", () => {
    expect(describeGraphError(400, { error: { code: 131047, message: "Re-engagement message" } })).toBe("(#131047) Re-engagement message");
    expect(describeGraphError(502, null)).toBe("HTTP 502");
    expect(sentMessageId({ messages: [{ id: "wamid.X" }] })).toBe("wamid.X");
    expect(sentMessageId({})).toBeNull();
  });
  it("keeps only messages changes with a valid phone_number_id", () => {
    expect(messageChanges(inbound)).toHaveLength(1);
    expect(messageChanges({ ...inbound, object: "page" })).toHaveLength(0);
    expect(messageChanges({ object: "whatsapp_business_account", entry: [{ changes: [{ field: "account_update", value: {} }] }] })).toHaveLength(0);
  });
  it("verifies X-Hub-Signature-256 over the raw body", async () => {
    const raw = new TextEncoder().encode(JSON.stringify(inbound));
    const good = "sha256=" + createHmac("sha256", APP_SECRET).update(raw).digest("hex");
    expect(await verifySignature(raw, good, APP_SECRET)).toBe(true);
    expect(await verifySignature(raw, good, "other-secret")).toBe(false);
    expect(await verifySignature(new TextEncoder().encode("{}"), good, APP_SECRET)).toBe(false);
    expect(await verifySignature(raw, null, APP_SECRET)).toBe(false);
  });
});

describe("whatsapp-webhook function", () => {
  it("answers the subscription challenge only for a known verify token", async () => {
    mockFetch((_url, init) => ok(JSON.parse(String(init?.body)).p_token === "good"));
    const yes = await handleWebhook(new Request("https://x/whatsapp-webhook?hub.mode=subscribe&hub.verify_token=good&hub.challenge=42"), deno);
    expect(yes.status).toBe(200);
    expect(await yes.text()).toBe("42");
    const no = await handleWebhook(new Request("https://x/whatsapp-webhook?hub.mode=subscribe&hub.verify_token=bad&hub.challenge=42"), deno);
    expect(no.status).toBe(403);
  });

  it("stores events only with a valid signature", async () => {
    const calls = mockFetch((url) => (url.endsWith("/whatsapp_app_secret") ? ok(APP_SECRET) : ok({ received: 1 })));
    const body = JSON.stringify(inbound);
    const sig = "sha256=" + createHmac("sha256", APP_SECRET).update(body).digest("hex");
    const res = await handleWebhook(new Request("https://x/whatsapp-webhook", { method: "POST", body, headers: { "X-Hub-Signature-256": sig } }), deno);
    expect(await res.json()).toEqual({ accepted: 1 });
    const ingest = calls.find((c) => c.url.endsWith("/whatsapp_ingest"));
    expect(ingest).toBeDefined();
    expect((ingest!.init!.headers as Record<string, string>).apikey).toBe("sb_secret_test");

    const forged = mockFetch((url) => (url.endsWith("/whatsapp_app_secret") ? ok(APP_SECRET) : ok({ received: 1 })));
    const bad = await handleWebhook(new Request("https://x/whatsapp-webhook", { method: "POST", body, headers: { "X-Hub-Signature-256": "sha256=" + "0".repeat(64) } }), deno);
    expect(await bad.json()).toEqual({ accepted: 0 });
    expect(forged.some((c) => c.url.endsWith("/whatsapp_ingest"))).toBe(false);
  });
});

describe("whatsapp function", () => {
  const send = (body: unknown) => new Request("https://x/whatsapp", {
    method: "POST", body: JSON.stringify(body), headers: { Authorization: "Bearer user-jwt", apikey: "sb_publishable_test" },
  });
  const claim = { message_id: "m1", phone_number_id: "1234567890", access_token: TOKEN, to: "77015551010", kind: "text", body: "Да" };

  it("requires the user's token", async () => {
    mockFetch(() => ok({}));
    const res = await handleSend(new Request("https://x/whatsapp", { method: "POST", body: "{}" }), deno);
    expect(res.status).toBe(401);
  });

  it("does not call Meta when the database rejects the message", async () => {
    const calls = mockFetch((url) => (url.endsWith("/whatsapp_queue_message") ? ok({ message: "whatsapp 24h window is closed" }, 400) : ok({})));
    const res = await handleSend(send({ action: "send", tenant: "t", phone: "+77015551010", text: "Да" }), deno);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "whatsapp 24h window is closed" });
    expect(calls.some((c) => c.url.includes("graph.facebook.com"))).toBe(false);
    // запрос в очередь идёт с токеном сотрудника, а не с сервисным ключом
    expect((calls[0].init!.headers as Record<string, string>).Authorization).toBe("Bearer user-jwt");
  });

  it("marks sent only with the id returned by Meta and never returns the token", async () => {
    const calls = mockFetch((url) => {
      if (url.endsWith("/whatsapp_queue_message")) return ok("m1");
      if (url.endsWith("/whatsapp_claim_message")) return ok(claim);
      if (url.includes("graph.facebook.com")) return ok({ messaging_product: "whatsapp", messages: [{ id: "wamid.OUT1" }] });
      return ok(null);
    });
    const res = await handleSend(send({ action: "send", tenant: "t", phone: "+77015551010", text: "Да" }), deno);
    const text = await res.text();
    expect(JSON.parse(text)).toEqual({ message_id: "m1", status: "sent", error: null });
    expect(text).not.toContain(TOKEN);
    const graph = calls.find((c) => c.url.includes("graph.facebook.com"))!;
    expect(graph.url).toBe("https://graph.facebook.com/v25.0/1234567890/messages");
    expect((graph.init!.headers as Record<string, string>).Authorization).toBe(`Bearer ${TOKEN}`);
    const finish = calls.find((c) => c.url.endsWith("/whatsapp_finish_message"))!;
    expect(JSON.parse(String(finish.init!.body))).toEqual({ p_message_id: "m1", p_wa_message_id: "wamid.OUT1", p_error: null });
  });

  it("records the Meta error as failed", async () => {
    const calls = mockFetch((url) => {
      if (url.endsWith("/whatsapp_queue_message")) return ok("m1");
      if (url.endsWith("/whatsapp_claim_message")) return ok(claim);
      if (url.includes("graph.facebook.com")) return ok({ error: { code: 131047, message: "Re-engagement message" } }, 400);
      return ok(null);
    });
    const res = await handleSend(send({ action: "send", tenant: "t", phone: "+77015551010", text: "Да" }), deno);
    expect(await res.json()).toEqual({ message_id: "m1", status: "failed", error: "(#131047) Re-engagement message" });
    const finish = calls.find((c) => c.url.endsWith("/whatsapp_finish_message"))!;
    expect(JSON.parse(String(finish.init!.body)).p_wa_message_id).toBeNull();
  });

  it("checks the connection and stores the result", async () => {
    const calls = mockFetch((url) => {
      if (url.endsWith("/whatsapp_begin_check")) return ok(null);
      if (url.endsWith("/whatsapp_credentials")) return ok({ phone_number_id: "1234567890", access_token: TOKEN });
      if (url.includes("graph.facebook.com")) return ok({ display_phone_number: "+7 701 555 10 10", verified_name: "Алтын", id: "1234567890" });
      return ok(null);
    });
    const res = await handleSend(send({ action: "check", tenant: "t" }), deno);
    const text = await res.text();
    expect(JSON.parse(text)).toEqual({ ok: true, display_phone: "+7 701 555 10 10", verified_name: "Алтын" });
    expect(text).not.toContain(TOKEN);
    const result = calls.find((c) => c.url.endsWith("/whatsapp_set_check_result"))!;
    expect(JSON.parse(String(result.init!.body))).toMatchObject({ p_tenant: "t", p_ok: true });
  });
});
