import type { TFunction } from "i18next";
import { formatKzt, type AppLanguage } from "./format";

export type PromoKind = "percent" | "fixed";
export type ReviewStatus = "new" | "published" | "hidden";

export interface PromoCode {
  id: string;
  code: string;
  description: string | null;
  kind: PromoKind;
  value: string | number;
  valid_from: string | null;
  valid_to: string | null;
  min_nights: number;
  max_uses: number | null;
  is_active: boolean;
}

export interface Review {
  id: string;
  booking_id: string;
  rating: number;
  comment: string | null;
  author_name: string | null;
  publish_consent: boolean;
  status: ReviewStatus;
  reply: string | null;
  created_at: string;
  booking?: { number: number; check_in: string; check_out: string; guest: { full_name: string } | null } | null;
}

export interface PublicReviews {
  count: number;
  average: number | string | null;
  items: { rating: number; comment: string | null; author_name: string | null; reply: string | null; month: string }[];
}

/** Код промокода как его хранит сервер: заглавные латинские буквы, цифры, «-» и «_», 3–30 символов */
export const PROMO_PATTERN = /^[A-Z0-9][A-Z0-9_-]{2,29}$/;

export function normalizePromoCode(input: string): string {
  return input.trim().toUpperCase().replace(/\s+/g, "");
}

/** «10%» или «5 000 ₸» */
export function promoValueText(p: Pick<PromoCode, "kind" | "value">, lang: AppLanguage = "ru"): string {
  return p.kind === "percent" ? `${Number(p.value)}%` : formatKzt(p.value, lang);
}

/** Ссылка на форму отзыва для гостя (одноразовая) */
export function reviewUrl(token: string, origin = window.location.origin, base = import.meta.env.BASE_URL): string {
  return `${origin}${base.replace(/\/?$/, "/")}review/${token}`;
}

/** Звёзды текстом для CSV и подсказок: 4 → «★★★★☆» */
export function starsText(rating: number): string {
  const r = Math.max(0, Math.min(5, Math.round(rating)));
  return "★".repeat(r) + "☆".repeat(5 - r);
}

export function describeMarketingError(error: unknown, t: TFunction): string | null {
  const e = (error ?? {}) as { message?: string; code?: string };
  const m = e.message ?? "";
  if (/promo code not found/.test(m)) return t("marketing.errors.notFound");
  if (/not valid for these dates/.test(m)) return t("marketing.errors.dates");
  if (/too short for this promo/.test(m)) return t("marketing.errors.nights");
  if (/usage limit/.test(m)) return t("marketing.errors.limit");
  if (/booking is closed/.test(m)) return t("marketing.errors.closed");
  if (/after check-out/.test(m)) return t("marketing.errors.afterCheckout");
  if (/review already received/.test(m)) return t("marketing.errors.alreadyReviewed");
  if (/did not allow publishing/.test(m)) return t("marketing.errors.noConsent");
  if (/review link is not valid/.test(m)) return t("review.invalid");
  if (e.code === "23505") return t("marketing.errors.duplicate");
  return null;
}
