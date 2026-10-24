import type { AppLanguage } from "./format";

export type SubscriptionStatus = "trialing" | "active" | "past_due" | "suspended" | "cancelled";
export type MemberStatus = "active" | "suspended";

export interface MyOrganization {
  tenant_id: string;
  slug: string;
  name: string;
  role_code: string;
  logo_path: string | null;
}

export interface Organization {
  id: string;
  slug: string;
  name: string;
  description: string | null;
  logo_path: string | null;
  address: string | null;
  city: string | null;
  phone: string | null;
  email: string | null;
  whatsapp_phone: string | null;
  legal_name: string | null;
  bin: string | null;
  timezone: string;
  currency: "KZT";
  default_language: AppLanguage;
  is_published: boolean;
}

export interface OrganizationSubscription {
  id: string;
  status: SubscriptionStatus;
  trial_ends_at: string | null;
  current_period_end: string | null;
  grace_days: number;
  plan: { code: string; name_ru: string; name_kk: string; features?: { feature_code: string }[] } | null;
}

export interface Role {
  id: string;
  code: string;
  name_ru: string;
  name_kk: string;
  is_system: boolean;
}

export interface PublicSanatorium {
  slug: string;
  name: string;
  description: string | null;
  logo_path: string | null;
  city: string | null;
  address: string | null;
  phone: string | null;
  email: string | null;
  whatsapp_phone: string | null;
  default_language: AppLanguage;
  check_in_time: string | null;
  check_out_time: string | null;
}

/** Коды разрешений из таблицы permissions */
export type Permission =
  | "settings.manage" | "members.read" | "members.manage" | "roles.manage" | "billing.manage" | "audit.read"
  | "media.write" | "rooms.read" | "rooms.write" | "rooms.status" | "rooms.delete"
  | "guests.read" | "guests.write" | "guests.notes" | "guests.export" | "guests.archive"
  | "bookings.read" | "bookings.write" | "bookings.checkin" | "bookings.cancel"
  | "leads.read" | "leads.write" | "finance.read" | "finance.write" | "payments.accept" | "refunds.create"
  | "reports.read" | "procedures.read" | "procedures.write" | "procedures.status"
  | "medical.read" | "medical.write" | "inventory.read" | "inventory.write"
  | "tasks.read" | "tasks.write" | "staff.read" | "staff.write"
  | "messages.read" | "messages.send" | "marketing.read" | "marketing.write";
