import type { TFunction } from "i18next";
import { describeError } from "./errors";

export type PaymentMethod = "cash" | "card" | "kaspi_transfer" | "bank_transfer" | "other";
export type PaymentKind = "payment" | "refund";

export const PAYMENT_METHODS: PaymentMethod[] = ["cash", "card", "kaspi_transfer", "bank_transfer", "other"];

export interface BookingPayment {
  id: string;
  booking_id: string;
  kind: PaymentKind;
  method: PaymentMethod;
  amount: string | number;
  paid_at: string;
  note: string | null;
  voided_at: string | null;
  void_reason: string | null;
}

export interface BookingExtra {
  id: string;
  booking_id: string;
  name: string;
  quantity: string | number;
  unit_price: string | number;
  amount: string | number;
}

export interface BookingBalance {
  booking_id: string;
  accommodation: string | number;
  extras: string | number;
  charges: string | number;
  paid: string | number;
  refunded: string | number;
  paid_net: string | number;
  balance: string | number;
  /** Процедуры по брони (запланированные и проведённые); до обновления базы поля может не быть */
  procedures?: string | number;
}

export interface ExpenseCategory { id: string; name: string; is_active: boolean }

export interface Expense {
  id: string;
  category_id: string;
  amount: string | number;
  spent_on: string;
  method: PaymentMethod;
  vendor: string | null;
  note: string | null;
  voided_at: string | null;
  void_reason: string | null;
  created_at: string;
}

export interface FinanceReport {
  from: string;
  to: string;
  payments: number;
  refunds: number;
  expenses: number;
  receivables: number;
  by_method: Partial<Record<PaymentMethod, number>>;
  expenses_by_category: { name: string; amount: number }[];
}

/** Сумма в тенге из поля формы: «12 500», «12500,5» → 12500.5; null, если не число или больше 2 знаков после запятой */
export function parseAmount(input: string): number | null {
  const clean = input.replace(/[\s ]/g, "").replace(",", ".");
  if (!/^\d+(\.\d{1,2})?$/.test(clean)) return null;
  const value = Number(clean);
  return value > 0 && value <= 1_000_000_000 ? value : null;
}

/** Первый и последний день месяца (YYYY-MM-DD) для даты YYYY-MM-DD */
export function monthBounds(isoDate: string): { from: string; to: string } {
  const [y, m] = isoDate.split("-").map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const mm = String(m).padStart(2, "0");
  return { from: `${y}-${mm}-01`, to: `${y}-${mm}-${String(last).padStart(2, "0")}` };
}

/** CSV для Excel: разделитель «;», BOM для кириллицы, экранирование кавычек и защита от формул */
export function toCsv(rows: (string | number | null)[][]): string {
  const cell = (v: string | number | null) => {
    let s = v === null ? "" : String(v);
    if (/^[=+\-@\t\r]/.test(s) && typeof v === "string") s = `'${s}`;
    return /[;"\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return "﻿" + rows.map((r) => r.map(cell).join(";")).join("\r\n");
}

export function downloadCsv(filename: string, rows: (string | number | null)[][]) {
  const url = URL.createObjectURL(new Blob([toCsv(rows)], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function describeFinanceError(error: unknown, t: TFunction): string {
  const m = ((error ?? {}) as { message?: string }).message ?? "";
  if (/refund exceeds/.test(m)) return t("finance.errors.refundTooBig");
  if (/refund reason|void reason/.test(m)) return t("finance.errors.reasonRequired");
  if (/cancelled booking|booking is cancelled/.test(m)) return t("finance.errors.cancelled");
  if (/already voided/.test(m)) return t("finance.errors.alreadyVoided");
  if (/amount must be/.test(m)) return t("finance.errors.amount");
  if (/expense_categories_tenant_id_name/.test(m)) return t("finance.errors.categoryExists");
  return describeError(error, t);
}
