import type { TFunction } from "i18next";
import type { AppLanguage } from "./format";

export const INVENTORY_CATEGORIES = ["linen", "amenities", "cleaning", "food", "medical", "office", "other"] as const;
export type InventoryCategory = (typeof INVENTORY_CATEGORIES)[number];
export const MOVE_KINDS = ["receipt", "issue", "writeoff", "adjustment"] as const;
export type MoveKind = (typeof MOVE_KINDS)[number];

/** Единицы измерения для подсказки; можно ввести свою */
export const UNIT_SUGGESTIONS = ["шт", "компл", "кг", "л", "упак", "рулон", "пара"];

export interface InventoryItem {
  id: string;
  name: string;
  category: InventoryCategory;
  unit: string;
  quantity: string | number;
  min_quantity: string | number;
  is_active: boolean;
}

export interface InventoryMovement {
  id: string;
  item_id: string;
  kind: MoveKind;
  quantity: string | number;
  balance_after: string | number;
  unit_cost: string | number | null;
  room_id: string | null;
  note: string | null;
  created_by: string | null;
  created_at: string;
}

export type StockLevel = "out" | "low" | "ok";

/** Нет на складе, заканчивается (остаток не выше минимума) или в норме */
export function stockLevel(item: Pick<InventoryItem, "quantity" | "min_quantity">): StockLevel {
  const q = Number(item.quantity);
  if (q <= 0) return "out";
  return q <= Number(item.min_quantity) ? "low" : "ok";
}

/** Количество из поля формы: «12», «2,5», «0.125» → число; null, если не число или больше 3 знаков после запятой */
export function parseQuantity(input: string, allowZero = false): number | null {
  const clean = input.replace(/[\s ]/g, "").replace(",", ".");
  if (!/^\d+(\.\d{1,3})?$/.test(clean)) return null;
  const value = Number(clean);
  if (value > 100_000_000) return null;
  return value > 0 || (allowZero && value === 0) ? value : null;
}

/** Остаток после операции; для пересчёта количество — это фактический остаток */
export function balanceAfter(kind: MoveKind, current: number, quantity: number): number {
  const delta = kind === "receipt" ? quantity : kind === "adjustment" ? quantity - current : -quantity;
  return Math.round((current + delta) * 1000) / 1000;
}

/** Количество без лишних нулей: 12.000 → «12», 2.500 → «2,5» */
export function formatQty(value: string | number, lang: AppLanguage = "ru"): string {
  return Number(value).toLocaleString(lang === "kk" ? "kk-KZ" : "ru-RU", { maximumFractionDigits: 3 });
}

export function describeInventoryError(error: unknown, t: TFunction): string | null {
  const e = (error ?? {}) as { message?: string; code?: string };
  const m = e.message ?? "";
  if (/not enough stock/.test(m)) return t("inventory.errors.notEnough");
  if (/writeoff reason/.test(m)) return t("inventory.errors.reason");
  if (/invalid quantity/.test(m)) return t("inventory.errors.quantity");
  if (/archived/.test(m)) return t("inventory.errors.archived");
  if (e.code === "23505") return t("inventory.errors.duplicate");
  return null;
}
