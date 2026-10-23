import type { TFunction } from "i18next";

/** Ошибки Supabase/PostgreSQL → понятный пользователю текст. Детали не показываются. */
export function describeError(error: unknown, t: TFunction): string {
  const e = (error ?? {}) as { message?: string; code?: string; status?: number; name?: string };
  const message = e.message ?? "";
  if (e.name === "TypeError" && /fetch/i.test(message)) return t("common.networkError");
  if (/invalid login credentials/i.test(message)) return t("auth.errors.invalidCredentials");
  if (/email not confirmed/i.test(message)) return t("auth.errors.emailNotConfirmed");
  if (/already registered|user already exists/i.test(message)) return t("auth.errors.userExists");
  if (e.status === 429 || /rate limit/i.test(message)) return t("auth.errors.rateLimited");
  if (/weak password|password should/i.test(message)) return t("auth.errors.weakPassword");
  if (e.code === "42501") return t("common.forbiddenText");
  return t("common.errorGeneric");
}
