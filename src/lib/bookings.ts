import type { TFunction } from "i18next";
import { describeError } from "./errors";

export type RoomStatus = "available" | "occupied" | "cleaning" | "maintenance";
export type BookingStatus = "new_request" | "confirmed" | "checked_in" | "checked_out" | "cancelled" | "no_show";
export type BookingSource = "walk_in" | "phone" | "whatsapp" | "website" | "agent" | "other";

export const ROOM_STATUSES: RoomStatus[] = ["available", "occupied", "cleaning", "maintenance"];
export const BOOKING_SOURCES: BookingSource[] = ["phone", "walk_in", "whatsapp", "website", "agent", "other"];

export interface RoomType {
  id: string;
  name: string;
  description: string | null;
  base_occupancy: number;
  max_occupancy: number;
  base_price: string | number;
  extra_guest_price: string | number;
  is_public: boolean;
  is_active: boolean;
  sort_order: number;
}

export interface RoomRate {
  id: string;
  room_type_id: string;
  name: string;
  starts_on: string;
  ends_on: string;
  price_per_night: string | number;
  extra_guest_price: string | number | null;
}

export interface Room {
  id: string;
  room_type_id: string;
  number: string;
  floor: string | null;
  building: string | null;
  status: RoomStatus;
  notes: string | null;
  is_active: boolean;
}

export interface Guest {
  id: string;
  full_name: string;
  phone: string | null;
  email: string | null;
  birth_date: string | null;
  city: string | null;
  notes: string | null;
  archived_at: string | null;
  created_at: string;
}

export interface Booking {
  id: string;
  number: number;
  guest_id: string;
  room_type_id: string;
  room_id: string | null;
  check_in: string;
  check_out: string;
  nights: number;
  adults: number;
  children: number;
  status: BookingStatus;
  source: BookingSource;
  total_amount: string | number;
  guest_comment: string | null;
  internal_notes: string | null;
  cancel_reason: string | null;
  created_at: string;
  guest?: Pick<Guest, "id" | "full_name" | "phone"> | null;
}

export interface Quote {
  total: number;
  nights: number;
  extra_guests?: number;
}

export const BOOKING_SELECT =
  "id, number, guest_id, room_type_id, room_id, check_in, check_out, nights, adults, children, status, source, total_amount, guest_comment, internal_notes, cancel_reason, created_at, guest:guests(id, full_name, phone)";

/** Брони, которые занимают номер (совпадает с условием exclusion constraint в БД) */
export const OCCUPYING_STATUSES: BookingStatus[] = ["confirmed", "checked_in", "checked_out"];

export const bookingStatusVariant: Record<BookingStatus, "default" | "success" | "warning" | "destructive" | "secondary" | "outline"> = {
  new_request: "warning",
  confirmed: "default",
  checked_in: "success",
  checked_out: "secondary",
  cancelled: "destructive",
  no_show: "destructive",
};

export const roomStatusVariant: Record<RoomStatus, "default" | "success" | "warning" | "destructive" | "secondary"> = {
  available: "success",
  occupied: "default",
  cleaning: "warning",
  maintenance: "destructive",
};

// ---------------------------------------------------------------------------
// Календарные даты в формате YYYY-MM-DD (без часового пояса)
// ---------------------------------------------------------------------------

const toUtc = (iso: string) => {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  return Date.UTC(y, m - 1, d);
};
const fromUtc = (ms: number) => new Date(ms).toISOString().slice(0, 10);

export function addDays(iso: string, days: number): string {
  return fromUtc(toUtc(iso) + days * 86_400_000);
}

export function diffDays(from: string, to: string): number {
  return Math.round((toUtc(to) - toUtc(from)) / 86_400_000);
}

export function dateRange(start: string, days: number): string[] {
  return Array.from({ length: days }, (_, i) => addDays(start, i));
}

/** Пересекаются ли проживания [inA, outA) и [inB, outB): выезд в день заезда — не пересечение */
export function staysOverlap(inA: string, outA: string, inB: string, outB: string): boolean {
  return inA < outB && inB < outA;
}

/** Ошибки серверных функций бронирования → понятный текст */
export function describeBookingError(error: unknown, t: TFunction): string {
  const e = (error ?? {}) as { code?: string; message?: string };
  const m = e.message ?? "";
  if (e.code === "23P01" && /room_rates/.test(m)) return t("rooms.errors.seasonOverlap");
  if (e.code === "23P01") return t("bookings.errors.roomTaken");
  if (e.code === "23505" && /rooms_tenant_id_number/.test(m)) return t("rooms.errors.numberTaken");
  if (e.code === "23505" && /guests_tenant_phone/.test(m)) return t("guests.errors.phoneTaken");
  if (e.code === "23503") return t("rooms.errors.inUse");
  if (e.code === "54000" && /room limit/.test(m)) return t("rooms.errors.limit");
  if (e.code === "54000") return t("public.booking.tooMany");
  if (/too many guests/.test(m)) return t("bookings.errors.capacity");
  if (/before the arrival date|only from the arrival date/.test(m)) return t("bookings.errors.tooEarly");
  if (/stay has already ended/.test(m)) return t("bookings.errors.ended");
  if (/reason is required/.test(m)) return t("bookings.errors.reasonRequired");
  if (/room is required/.test(m)) return t("bookings.errors.roomRequired");
  if (/entirely in the past/.test(m)) return t("bookings.errors.past");
  if (/not available for booking|does not belong/.test(m)) return t("bookings.errors.roomUnavailable");
  if (/check-out must be after/.test(m)) return t("bookings.errors.dates");
  if (/guest is checked in/.test(m)) return t("rooms.errors.guestInside");
  return describeError(error, t);
}
