import type { TFunction } from "i18next";
import { formatDateTime, formatKzt, type AppLanguage } from "./format";

export interface AuditEntry {
  id: number;
  actor_user_id: string | null;
  action: string;
  entity_type: string | null;
  entity_id: string | null;
  result: "success" | "denied" | "error";
  details: Record<string, unknown>;
  created_at: string;
}

/** Группы журнала: префиксы кодов действий */
export const AUDIT_GROUPS = {
  bookings: ["booking.", "guest.", "room.status"],
  finance: ["payment.", "expense.", "expense_category."],
  procedures: ["procedure.", "procedure_type.", "treatment_room."],
  tasks: ["task."],
  inventory: ["inventory."],
  marketing: ["review.", "promo_code."],
  catalog: ["room_type.", "room_rate.", "room.create", "room.update", "room.delete"],
  staff: ["member.", "role.", "organization."],
  settings: ["settings.", "billing.", "admin."],
} as const;
export type AuditGroup = keyof typeof AUDIT_GROUPS;

/** Фильтр PostgREST для группы: action.like.booking.*,action.like.guest.* … */
export function auditGroupFilter(group: AuditGroup): string {
  return AUDIT_GROUPS[group].map((p) => `action.like.${p.endsWith(".") ? `${p}*` : p}`).join(",");
}

const MONEY_KEYS = new Set(["amount", "price", "base_price", "extra_guest_price", "price_per_night", "unit_price"]);

/** Название действия: перевод по коду, иначе сам код (новые события не теряются) */
export function auditActionLabel(action: string, t: TFunction): string {
  const key = `audit.actions.${action.replace(/\./g, "_")}`;
  const label = t(key);
  return label === key ? action : label;
}

function fieldLabel(key: string, t: TFunction): string {
  const k = `audit.fields.${key}`;
  const label = t(k);
  return label === k ? key : label;
}

const STATUS_NAMESPACES = ["bookings.status", "procedures.status", "tasks.status", "subscription.status", "rooms.status", "audit.roles"];

/** Поле → пространство переводов его значений */
const VALUE_NAMESPACES: Record<string, string> = { period: "billing.period", source: "bookings.source", method: "finance.method", category: "inventory.categories", plan: "audit.plans" };

function translated(key: string, t: TFunction): string | null {
  const label = t(key);
  return label === key ? null : label;
}

function valueText(key: string, value: unknown, lang: AppLanguage, t: TFunction, tz?: string): string {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(value)) return formatDateTime(value, lang, tz);
  if (typeof value === "string" && /^[a-z_]+$/.test(value) && ["status", "from", "to"].includes(key)) {
    for (const ns of STATUS_NAMESPACES) {
      const label = translated(`${ns}.${value}`, t);
      if (label) return label;
    }
  }
  if (typeof value === "string" && VALUE_NAMESPACES[key]) return translated(`${VALUE_NAMESPACES[key]}.${value}`, t) ?? value;
  if (MONEY_KEYS.has(key) && (typeof value === "number" || typeof value === "string")) return formatKzt(value, lang);
  if (typeof value === "boolean") return t(value ? "audit.yes" : "audit.no");
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

/**
 * Короткое описание подробностей события для человека.
 * Значения берутся только из полей, которые сервер сам записал в details (без персональных данных гостей).
 */
export function auditDetailsText(details: Record<string, unknown> | null, lang: AppLanguage, t: TFunction, tz?: string): string {
  if (!details) return "";
  const parts: string[] = [];
  const values = details.values as Record<string, unknown> | undefined;
  const changed = details.changed as string[] | undefined;
  if (values && typeof values === "object") {
    for (const [k, v] of Object.entries(values)) {
      if (v && typeof v === "object" && "from" in (v as object)) {
        const fv = v as { from: unknown; to: unknown };
        parts.push(`${fieldLabel(k, t)}: ${valueText(k, fv.from, lang, t, tz)} → ${valueText(k, fv.to, lang, t, tz)}`);
      } else {
        parts.push(`${fieldLabel(k, t)}: ${valueText(k, v, lang, t, tz)}`);
      }
    }
  }
  if (Array.isArray(changed)) {
    const rest = changed.filter((k) => !values || !(k in values));
    if (rest.length) parts.push(`${t("audit.changedFields")}: ${rest.map((k) => fieldLabel(k, t)).join(", ")}`);
  }
  for (const [k, v] of Object.entries(details)) {
    if (k === "values" || k === "changed" || k.endsWith("_id") || v === null || v === undefined) continue;
    parts.push(`${fieldLabel(k, t)}: ${valueText(k, v, lang, t, tz)}`);
  }
  return parts.join(" · ");
}
