import type { TFunction } from "i18next";
import { describeError } from "./errors";
import type { BookingStatus } from "./bookings";

export type MedicalVisitKind = "initial" | "follow_up" | "final";
export type PrescriptionStatus = "active" | "completed" | "cancelled";

export const VISIT_KINDS: MedicalVisitKind[] = ["initial", "follow_up", "final"];

export interface MedicalRecord {
  allergies: string | null;
  contraindications: string | null;
  chronic_conditions: string | null;
  medications: string | null;
  notes: string | null;
  consent_at: string;
  updated_at: string;
  updated_by_name: string | null;
}

export interface MedicalVisit {
  id: string;
  booking_id: string | null;
  kind: MedicalVisitKind;
  visit_at: string;
  complaints: string | null;
  examination: string | null;
  diagnosis: string | null;
  recommendations: string | null;
  blood_pressure: string | null;
  pulse: number | null;
  temperature: number | null;
  weight: number | null;
  doctor_name: string | null;
  created_at: string;
  editable: boolean;
}

export interface Prescription {
  id: string;
  booking_id: string | null;
  procedure_type_id: string;
  procedure: string;
  sessions: number;
  done: number;
  frequency: string | null;
  note: string | null;
  status: PrescriptionStatus;
  prescribed_by_name: string | null;
  created_at: string;
}

export interface MedicalCard {
  guest: { id: string; full_name: string; birth_date: string | null; city: string | null };
  record: MedicalRecord | null;
  visits: MedicalVisit[];
  prescriptions: Prescription[];
  /** Текущее или ближайшее проживание: к нему привязываются осмотры и назначения */
  stay: { id: string; number: number; check_in: string; check_out: string; status: BookingStatus } | null;
  can_write: boolean;
}

export interface MedicalOverviewRow {
  guest_id: string;
  full_name: string;
  booking_id: string;
  booking_number: number;
  room_number: string | null;
  check_in: string;
  check_out: string;
  status: BookingStatus;
  has_card: boolean;
  has_initial: boolean;
  active_prescriptions: number;
}

export const RECORD_FIELDS = ["allergies", "contraindications", "chronic_conditions", "medications", "notes"] as const;
export type RecordField = (typeof RECORD_FIELDS)[number];

export const prescriptionStatusVariant: Record<PrescriptionStatus, "default" | "success" | "secondary"> = {
  active: "default",
  completed: "success",
  cancelled: "secondary",
};

/** Полных лет на дату (ISO), null если дата рождения неизвестна */
export function ageOn(birthDate: string | null, today: string): number | null {
  if (!birthDate) return null;
  const [by, bm, bd] = birthDate.split("-").map(Number);
  const [ty, tm, td] = today.split("-").map(Number);
  return ty - by - (tm < bm || (tm === bm && td < bd) ? 1 : 0);
}

/** Давление в виде «120/80» (пустое значение допустимо) */
export function isBloodPressure(value: string): boolean {
  return value.trim() === "" || /^\d{2,3}\/\d{2,3}$/.test(value.trim());
}

/** Число из поля ввода: пусто → null, запятая как десятичный разделитель */
export function parseMeasure(value: string): number | null {
  const v = value.trim().replace(",", ".");
  if (v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : NaN;
}

/** Что ещё не сделано по гостю: нет карты, нет первичного осмотра */
export function overviewNeeds(row: Pick<MedicalOverviewRow, "has_card" | "has_initial">): "card" | "initial" | null {
  if (!row.has_card) return "card";
  if (!row.has_initial) return "initial";
  return null;
}

export function describeMedicalError(error: unknown, t: TFunction): string {
  const m = ((error ?? {}) as { message?: string }).message ?? "";
  if (/medical consent is required/.test(m)) return t("medical.errors.consent");
  if (/medical card is required/.test(m)) return t("medical.errors.noCard");
  if (/visit is empty/.test(m)) return t("medical.errors.emptyVisit");
  if (/invalid vitals/.test(m)) return t("medical.errors.vitals");
  if (/invalid visit time/.test(m)) return t("medical.errors.visitTime");
  if (/visit is locked/.test(m)) return t("medical.errors.locked");
  if (/invalid sessions/.test(m)) return t("medical.errors.sessions");
  if (/procedure type not found/.test(m)) return t("medical.errors.procedure");
  if (/status change is not allowed/.test(m)) return t("medical.errors.status");
  if (/text is too long/.test(m)) return t("validation.tooLong");
  return describeError(error, t);
}
