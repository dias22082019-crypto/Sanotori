import type { TFunction } from "i18next";
import { describeError } from "./errors";
import type { BookingStatus } from "./bookings";

export type Meal = "breakfast" | "lunch" | "dinner";
export const MEALS: Meal[] = ["breakfast", "lunch", "dinner"];

export interface DietType {
  id: string;
  code: string;
  name: string;
  description: string | null;
  is_default: boolean;
  is_active: boolean;
  sort: number;
}

export interface KitchenGuest {
  booking_id: string;
  booking_number: number;
  status: BookingStatus;
  full_name: string;
  room: string | null;
  persons: number;
  meals: Meal[];
  diet_type_id: string | null;
  kitchen_note: string | null;
}

export interface KitchenDay {
  date: string;
  guests: KitchenGuest[];
  portions: { meal: Meal; diet_type_id: string | null; portions: number }[];
  menus: { meal: Meal; diet_type_id: string; dishes: string }[];
  can_write: boolean;
  can_set_diet: boolean;
}

export interface BookingDiet {
  diet: { diet_type_id: string; code: string; name: string; kitchen_note: string | null; updated_at: string; set_by_name: string | null } | null;
  default: { diet_type_id: string; code: string; name: string } | null;
  can_set: boolean;
}

export const DIET_SELECT = "id, code, name, description, is_default, is_active, sort";

export function sortDiets<T extends Pick<DietType, "sort" | "code">>(list: T[]): T[] {
  return [...list].sort((a, b) => a.sort - b.sort || a.code.localeCompare(b.code, "ru", { numeric: true }));
}

export interface PortionRow {
  /** null — гости без стола (в санатории не задан стол по умолчанию) */
  dietId: string | null;
  counts: Record<Meal, number>;
  total: number;
}

/** Таблица порций: строка на стол (в порядке справочника, пустые не показываются), итог по приёмам пищи */
export function portionGrid(day: Pick<KitchenDay, "portions">, diets: Pick<DietType, "id">[]): { rows: PortionRow[]; totals: Record<Meal, number> } {
  const byDiet = new Map<string | null, PortionRow>();
  const totals: Record<Meal, number> = { breakfast: 0, lunch: 0, dinner: 0 };
  for (const p of day.portions) {
    const row = byDiet.get(p.diet_type_id) ?? { dietId: p.diet_type_id, counts: { breakfast: 0, lunch: 0, dinner: 0 }, total: 0 };
    row.counts[p.meal] += p.portions;
    row.total += p.portions;
    totals[p.meal] += p.portions;
    byDiet.set(p.diet_type_id, row);
  }
  const order = new Map(diets.map((d, i) => [d.id as string | null, i]));
  const rows = [...byDiet.values()].sort((a, b) => (order.get(a.dietId) ?? 1e6) - (order.get(b.dietId) ?? 1e6));
  return { rows, totals };
}

export function describeKitchenError(error: unknown, t: TFunction): string {
  const m = ((error ?? {}) as { message?: string }).message ?? "";
  if (/diet code already exists/.test(m)) return t("kitchen.errors.codeExists");
  if (/code and name are required/.test(m)) return t("kitchen.errors.codeName");
  if (/default diet must be active/.test(m)) return t("kitchen.errors.defaultActive");
  if (/source menu is empty/.test(m)) return t("kitchen.errors.emptySource");
  if (/booking is closed/.test(m)) return t("kitchen.errors.closed");
  if (/diet type not found/.test(m)) return t("kitchen.errors.dietNotFound");
  if (/invalid dates/.test(m)) return t("kitchen.errors.dates");
  if (/text is too long/.test(m)) return t("validation.tooLong");
  return describeError(error, t);
}
