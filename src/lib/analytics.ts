import { addDays } from "./bookings";
import { monthBounds } from "./finance";

export interface AnalyticsReport {
  from: string;
  to: string;
  days: number;
  rooms: number;
  room_nights: number;
  accommodation: number | string;
  received: number | string;
  expenses: number | string;
  guests: number;
  returning_guests: number;
  daily: { day: string; occupied: number }[];
  monthly: { month: string; days: number; room_nights: number; accommodation: number | string; received: number | string; expenses: number | string }[];
  bookings: { created: number; cancelled: number; no_show: number; requests: number; avg_nights: number | string; avg_lead_days: number | string };
  sources: { source: string; bookings: number; cancelled: number; amount: number | string }[];
  room_types: { name: string; rooms: number; room_nights: number; accommodation: number | string }[];
  procedures: { name: string; done: number; no_show: number; amount: number | string }[];
}

export const ANALYTICS_PRESETS = ["thisMonth", "lastMonth", "last3Months", "thisYear", "custom"] as const;
export type AnalyticsPreset = (typeof ANALYTICS_PRESETS)[number];

/** Период для готового варианта; today — сегодняшняя дата санатория (YYYY-MM-DD) */
export function presetRange(preset: Exclude<AnalyticsPreset, "custom">, today: string): { from: string; to: string } {
  const month = monthBounds(today);
  switch (preset) {
    case "thisMonth":
      return { from: month.from, to: today };
    case "lastMonth":
      return monthBounds(addDays(month.from, -1));
    case "last3Months": {
      const start = monthBounds(addDays(monthBounds(addDays(month.from, -1)).from, -1)).from;
      return { from: start, to: today };
    }
    case "thisYear":
      return { from: `${today.slice(0, 4)}-01-01`, to: today };
  }
}

/** Доля в процентах с одним знаком; 0, если знаменатель пустой */
export function percent(part: number, whole: number): number {
  return whole > 0 ? Math.round((part / whole) * 1000) / 10 : 0;
}

export interface AnalyticsKpi {
  occupancy: number;
  adr: number;
  revpar: number;
  cancelRate: number;
}

/**
 * Показатели гостиничного учёта:
 * загрузка — проданные номеро-ночи / (номера × дни); ADR — начислено за проживание / проданные ночи;
 * RevPAR — начислено за проживание / (номера × дни).
 */
export function kpis(r: AnalyticsReport): AnalyticsKpi {
  const capacity = r.rooms * r.days;
  const accommodation = Number(r.accommodation);
  return {
    occupancy: percent(r.room_nights, capacity),
    adr: r.room_nights > 0 ? Math.round(accommodation / r.room_nights) : 0,
    revpar: capacity > 0 ? Math.round(accommodation / capacity) : 0,
    cancelRate: percent(r.bookings.cancelled + r.bookings.no_show, r.bookings.created),
  };
}

/** Точки графика загрузки: по дням для периода до 62 дней, иначе по месяцам */
export function occupancySeries(r: AnalyticsReport): { key: string; occupancy: number; byMonth: boolean }[] {
  if (r.days <= 62) {
    return r.daily.map((d) => ({ key: d.day, occupancy: percent(d.occupied, r.rooms), byMonth: false }));
  }
  return r.monthly.map((m) => ({ key: m.month, occupancy: percent(m.room_nights, r.rooms * m.days), byMonth: true }));
}
