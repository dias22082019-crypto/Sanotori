import type { TFunction } from "i18next";
import { describeError } from "./errors";
import type { BookingSource } from "./bookings";

export type LeadStatus = "new" | "in_progress" | "won" | "lost";
export type LeadLostReason = "price" | "no_dates" | "no_answer" | "competitor" | "not_relevant" | "booking_cancelled" | "other";

export interface Lead {
  id: string;
  number: number;
  status: LeadStatus;
  source: BookingSource;
  full_name: string | null;
  phone: string | null;
  guest_id: string | null;
  booking_id: string | null;
  room_type_id: string | null;
  check_in: string | null;
  check_out: string | null;
  adults: number | null;
  children: number | null;
  interest: string | null;
  comment: string | null;
  assignee_id: string | null;
  next_contact_at: string | null;
  lost_reason: LeadLostReason | null;
  lost_note: string | null;
  created_at: string;
  closed_at: string | null;
  guest?: { id: string; full_name: string; phone: string | null } | null;
}

export interface LeadNote {
  id: string;
  body: string;
  created_by: string | null;
  created_at: string;
}

export interface LeadCounts {
  new: number;
  open: number;
  overdue: number;
  mine: number;
}

export const LEAD_SELECT =
  "id, number, status, source, full_name, phone, guest_id, booking_id, room_type_id, check_in, check_out, adults, children, interest, comment, assignee_id, next_contact_at, lost_reason, lost_note, created_at, closed_at, guest:guests(id, full_name, phone)";

/** Причины отказа, которые сотрудник выбирает сам («бронь отменена» ставит сервер) */
export const LOST_REASONS: LeadLostReason[] = ["price", "no_dates", "no_answer", "competitor", "not_relevant", "other"];

export const LEAD_TABS = ["open", "won", "lost", "all"] as const;
export type LeadTab = (typeof LEAD_TABS)[number];

export function leadStatusesFor(tab: LeadTab): LeadStatus[] | null {
  return tab === "open" ? ["new", "in_progress"] : tab === "won" ? ["won"] : tab === "lost" ? ["lost"] : null;
}

export const leadStatusVariant: Record<LeadStatus, "default" | "secondary" | "success" | "destructive"> = {
  new: "default",
  in_progress: "secondary",
  won: "success",
  lost: "destructive",
};

export function isLeadOpen(lead: Pick<Lead, "status">): boolean {
  return lead.status === "new" || lead.status === "in_progress";
}

/** Пора связаться: срок контакта прошёл, а заявка ещё открыта */
export function isContactOverdue(lead: Pick<Lead, "status" | "next_contact_at">, now = Date.now()): boolean {
  return isLeadOpen(lead) && Boolean(lead.next_contact_at) && Date.parse(lead.next_contact_at!) < now;
}

/** Открытые сначала: просроченный контакт, затем ближайший контакт, затем новые сверху */
export function sortLeads<T extends Pick<Lead, "status" | "next_contact_at" | "created_at">>(list: T[], now = Date.now()): T[] {
  const rank = (l: T) => (isContactOverdue(l, now) ? 0 : isLeadOpen(l) && l.next_contact_at ? 1 : isLeadOpen(l) ? 2 : 3);
  return [...list].sort((a, b) => {
    const r = rank(a) - rank(b);
    if (r !== 0) return r;
    if (rank(a) <= 1) return Date.parse(a.next_contact_at!) - Date.parse(b.next_contact_at!);
    return Date.parse(b.created_at) - Date.parse(a.created_at);
  });
}

export function describeLeadError(error: unknown, t: TFunction): string {
  const m = ((error ?? {}) as { message?: string }).message ?? "";
  if (/name or phone is required/.test(m)) return t("leads.errors.contact");
  if (/invalid phone/.test(m)) return t("validation.phone");
  if (/invalid dates/.test(m)) return t("leads.errors.dates");
  if (/invalid guests count/.test(m)) return t("leads.errors.guests");
  if (/assignee is not available/.test(m)) return t("leads.errors.assignee");
  if (/lead is closed/.test(m)) return t("leads.errors.closed");
  if (/lead already has a booking/.test(m)) return t("leads.errors.hasBooking");
  if (/lost reason is required/.test(m)) return t("leads.errors.reason");
  if (/status change is not allowed/.test(m)) return t("leads.errors.status");
  if (/note is required/.test(m)) return t("leads.errors.note");
  if (/text is too long/.test(m)) return t("validation.tooLong");
  return describeError(error, t);
}
