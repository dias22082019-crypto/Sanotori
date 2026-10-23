export const DEFAULT_TIMEZONE = "Asia/Almaty";

export type AppLanguage = "ru" | "kk";

const localeFor = (lang: AppLanguage) => (lang === "kk" ? "kk-KZ" : "ru-RU");

/** Сумма в тенге: 125000 → «125 000 ₸». Принимает строку из numeric, чтобы не терять точность. */
export function formatKzt(amount: number | string, lang: AppLanguage = "ru"): string {
  const value = typeof amount === "string" ? Number(amount) : amount;
  if (!Number.isFinite(value)) return "—";
  const formatted = new Intl.NumberFormat(localeFor(lang), {
    minimumFractionDigits: Number.isInteger(value) ? 0 : 2,
    maximumFractionDigits: 2,
  }).format(value);
  return `${formatted} ₸`;
}

/** Дата-время в часовом поясе санатория */
export function formatDateTime(iso: string, lang: AppLanguage = "ru", timeZone = DEFAULT_TIMEZONE): string {
  return new Intl.DateTimeFormat(localeFor(lang), {
    timeZone,
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(iso));
}

/** Календарная дата (YYYY-MM-DD, без часового пояса) */
export function formatDate(isoDate: string, lang: AppLanguage = "ru"): string {
  const [y, m, d] = isoDate.slice(0, 10).split("-").map(Number);
  return new Intl.DateTimeFormat(localeFor(lang), { timeZone: "UTC", day: "2-digit", month: "2-digit", year: "numeric" })
    .format(new Date(Date.UTC(y, m - 1, d)));
}

/** Сегодняшняя дата (YYYY-MM-DD) в часовом поясе санатория */
export function todayInTimeZone(timeZone = DEFAULT_TIMEZONE, now = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

/**
 * Нормализация казахстанского номера в E.164: «8 (701) 123-45-67» → «+77011234567».
 * Возвращает null, если номер не похож на казахстанский.
 */
export function normalizeKzPhone(input: string): string | null {
  const digits = input.replace(/\D/g, "");
  let national: string | null = null;
  if (digits.length === 11 && (digits.startsWith("7") || digits.startsWith("8"))) national = digits.slice(1);
  else if (digits.length === 10) national = digits;
  if (!national || !/^[67]\d{9}$/.test(national)) return null;
  return `+7${national}`;
}

/** «+77011234567» → «+7 701 123 45 67» */
export function formatKzPhone(e164: string): string {
  const m = /^\+7(\d{3})(\d{3})(\d{2})(\d{2})$/.exec(e164);
  return m ? `+7 ${m[1]} ${m[2]} ${m[3]} ${m[4]}` : e164;
}

/** Ссылка WhatsApp для публичной страницы */
export function whatsappLink(e164: string, text?: string): string {
  const base = `https://wa.me/${e164.replace(/\D/g, "")}`;
  return text ? `${base}?text=${encodeURIComponent(text)}` : base;
}

/** slug для адреса публичной страницы, совпадает с ограничением в БД */
export const SLUG_PATTERN = /^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$/;

const translit: Record<string, string> = {
  а: "a", ә: "a", б: "b", в: "v", г: "g", ғ: "g", д: "d", е: "e", ё: "e", ж: "zh", з: "z", и: "i", й: "y",
  к: "k", қ: "k", л: "l", м: "m", н: "n", ң: "n", о: "o", ө: "o", п: "p", р: "r", с: "s", т: "t", у: "u",
  ұ: "u", ү: "u", ф: "f", х: "h", һ: "h", ц: "ts", ч: "ch", ш: "sh", щ: "sch", ъ: "", ы: "y", і: "i", ь: "",
  э: "e", ю: "yu", я: "ya",
};

export function slugify(name: string): string {
  return name
    .toLowerCase()
    .split("")
    .map((ch) => translit[ch] ?? ch)
    .join("")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 50)
    .replace(/-+$/g, "");
}
