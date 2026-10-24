import type { TFunction } from "i18next";
import { supabase } from "./supabase";
import { formatKzt, type AppLanguage } from "./format";

export type MessageDirection = "in" | "out";
export type MessageStatus = "queued" | "sending" | "sent" | "delivered" | "read" | "failed" | "received";

/** Ответ whatsapp_settings: токены и App Secret не возвращаются никогда, verify_token — только владельцу настроек */
export interface WhatsappSettings {
  connected: boolean;
  feature: boolean;
  is_enabled?: boolean;
  phone_number_id?: string;
  waba_id?: string | null;
  has_token?: boolean;
  has_app_secret?: boolean;
  status?: "not_checked" | "ok" | "error";
  display_phone?: string | null;
  verified_name?: string | null;
  last_error?: string | null;
  checked_at?: string | null;
  verify_token?: string | null;
}

export interface MessageThread {
  phone: string;
  guest_id: string | null;
  guest_name: string | null;
  contact_name: string | null;
  last_at: string;
  last_direction: MessageDirection;
  last_body: string | null;
  last_kind: string;
  last_status: MessageStatus;
  unread: number;
  window_open: boolean;
}

export interface Message {
  id: string;
  direction: MessageDirection;
  phone: string;
  kind: "text" | "template" | "other";
  body: string | null;
  template_name: string | null;
  template_lang: string | null;
  status: MessageStatus;
  error: string | null;
  created_at: string;
}

export type SendInput = { tenant: string; phone: string; booking_id?: string | null } & (
  | { text: string }
  | { template_name: string; template_lang: string }
);

/** Имя шаблона и язык в том виде, в каком их принимает Meta и проверяет база */
export const TEMPLATE_NAME_PATTERN = /^[a-z0-9_]{1,512}$/;
export const TEMPLATE_LANG_PATTERN = /^[a-z]{2,3}(_[A-Z]{2})?$/;

/** Адрес вебхука для кабинета Meta */
export function webhookUrl(base = import.meta.env.VITE_SUPABASE_URL as string | undefined): string {
  return `${(base ?? "https://<project>.supabase.co").replace(/\/+$/, "")}/functions/v1/whatsapp-webhook`;
}

/** Текст сообщения гостю со ссылкой Kaspi; сумму сотрудник видит и проверяет сам */
export function kaspiPaymentText(t: TFunction, p: { name: string; number: number; amount: number | string; url: string; lang: AppLanguage }): string {
  return t("kaspi.messageText", { name: p.name, number: p.number, amount: formatKzt(p.amount, p.lang), url: p.url });
}

/**
 * Вызов Edge Function «whatsapp». Ошибку функции (HTTP 4xx/5xx) supabase-js отдаёт как FunctionsHttpError,
 * текст лежит в теле ответа — читаем его, чтобы показать понятное сообщение.
 */
export async function invokeWhatsapp<T>(body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke("whatsapp", { body });
  if (!error) return data as T;
  const ctx = (error as { context?: Response }).context;
  let message = error.message;
  if (ctx && typeof ctx.json === "function") {
    const payload = await ctx.json().catch(() => null) as { error?: string } | null;
    if (payload?.error) message = payload.error;
  }
  throw Object.assign(new Error(message), { name: error.name });
}

/** Ошибки базы, Edge Function и Meta → понятный текст; null — показать общий */
export function describeWhatsappError(error: unknown, t: TFunction): string | null {
  const e = (error ?? {}) as { message?: string; code?: string; name?: string };
  const m = e.message ?? "";
  if (/24h window is closed|#131047/.test(m)) return t("messages.errors.window");
  if (/whatsapp is not connected|credentials unavailable/.test(m)) return t("messages.errors.notConnected");
  if (/integrations are not available/.test(m)) return t("whatsapp.planNote");
  if (/invalid template|#132001/.test(m)) return t("messages.errors.template");
  if (/invalid phone|#131026/.test(m)) return t("messages.errors.phone");
  if (/text is too long/.test(m)) return t("messages.errors.tooLong");
  if (/invalid whatsapp ids/.test(m)) return t("whatsapp.errors.ids");
  if (/invalid whatsapp credentials/.test(m)) return t("whatsapp.errors.credentials");
  if (/access token is required/.test(m)) return t("whatsapp.errors.tokenRequired");
  if (/used by another sanatorium/.test(m) || e.code === "23505") return t("whatsapp.errors.duplicate");
  if (/#190\b|OAuthException|access token/i.test(m)) return t("whatsapp.errors.token");
  if (e.name === "FunctionsFetchError" || e.name === "FunctionsRelayError" || /Function not found|404/.test(m)) {
    return t("whatsapp.errors.function");
  }
  if (/function public\.(whatsapp_settings|message_threads)|relation "public\.messages"|PGRST202/.test(m) || e.code === "PGRST202" || e.code === "42P01") {
    return t("whatsapp.errors.migration");
  }
  return null;
}

/** Копирование в буфер обмена; false — браузер не разрешил */
export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}
