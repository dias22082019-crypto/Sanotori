import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { formatDateTime, formatKzt, type AppLanguage } from "@/lib/format";
import type { Booking } from "@/lib/bookings";
import {
  PAYMENT_METHODS, describeFinanceError, parseAmount,
  type BookingBalance, type BookingExtra, type BookingPayment, type PaymentKind, type PaymentMethod,
} from "@/lib/finance";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";

/** Деньги по броне: баланс, доп. услуги, оплаты и возвраты. Все суммы и права проверяет сервер. */
export function BookingPayments({ booking }: { booking: Booking }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable } = useOrg();
  const qc = useQueryClient();
  const seesPayments = can("finance.read") || can("payments.accept");
  const canPay = writable && can("payments.accept");
  const canRefund = writable && can("refunds.create");
  const canVoid = writable && can("finance.write");
  const canExtras = writable && (can("bookings.write") || can("finance.write"));
  const active = !["cancelled", "no_show"].includes(booking.status);

  const balance = useQuery({
    queryKey: ["booking-balance", org.id, booking.id],
    queryFn: async () => {
      const { data, error } = await supabase.from("booking_balances").select("*").eq("booking_id", booking.id).maybeSingle();
      if (error) throw error;
      return data as BookingBalance | null;
    },
  });
  const extras = useQuery({
    queryKey: ["booking-extras", org.id, booking.id],
    queryFn: async () => {
      const { data, error } = await supabase.from("booking_extras").select("*").eq("booking_id", booking.id).order("created_at");
      if (error) throw error;
      return data as BookingExtra[];
    },
  });
  const payments = useQuery({
    queryKey: ["booking-payments", org.id, booking.id],
    enabled: seesPayments,
    queryFn: async () => {
      const { data, error } = await supabase.from("booking_payments").select("*").eq("booking_id", booking.id).order("paid_at");
      if (error) throw error;
      return data as BookingPayment[];
    },
  });

  const refresh = () => {
    for (const key of ["booking-balance", "booking-extras", "booking-payments", "bookings", "finance"]) {
      void qc.invalidateQueries({ queryKey: [key, org.id] });
    }
  };

  const [mode, setMode] = useState<PaymentKind | "extra" | null>(null);
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState<PaymentMethod>("cash");
  const [note, setNote] = useState("");
  const [extraName, setExtraName] = useState("");
  const [extraQty, setExtraQty] = useState("1");
  const [busy, setBusy] = useState(false);
  const [voiding, setVoiding] = useState<string | null>(null);
  const [voidReason, setVoidReason] = useState("");

  const due = Number(balance.data?.balance ?? 0);
  const open = (m: PaymentKind | "extra") => {
    setMode(m);
    setNote("");
    setAmount(m === "payment" && due > 0 ? String(due) : "");
    setExtraName("");
    setExtraQty("1");
  };

  const submit = async () => {
    const value = parseAmount(amount);
    if (value === null) return toast.error(t("finance.errors.amount"));
    if (mode === "refund" && !note.trim()) return toast.error(t("finance.errors.reasonRequired"));
    setBusy(true);
    const { error } = mode === "extra"
      ? await supabase.rpc("add_booking_extra", { p_booking_id: booking.id, p_name: extraName, p_quantity: Number(extraQty.replace(",", ".")) || 1, p_unit_price: value })
      : await supabase.rpc("add_booking_payment", { p_booking_id: booking.id, p_kind: mode, p_method: method, p_amount: value, p_note: note || null });
    setBusy(false);
    if (error) return toast.error(describeFinanceError(error, t));
    toast.success(t(mode === "extra" ? "finance.extraAdded" : mode === "refund" ? "finance.refundAdded" : "finance.paymentAdded"));
    setMode(null);
    refresh();
  };

  const voidPayment = async (id: string) => {
    if (!voidReason.trim()) return toast.error(t("finance.errors.reasonRequired"));
    const { error } = await supabase.rpc("void_booking_payment", { p_payment_id: id, p_reason: voidReason });
    if (error) return toast.error(describeFinanceError(error, t));
    toast.success(t("finance.voided"));
    setVoiding(null);
    setVoidReason("");
    refresh();
  };

  const removeExtra = async (id: string) => {
    const { error } = await supabase.rpc("remove_booking_extra", { p_extra_id: id });
    if (error) return toast.error(describeFinanceError(error, t));
    refresh();
  };

  const b = balance.data;
  return (
    <section className="mt-5 border-t pt-4">
      <h3 className="text-sm font-semibold">{t("finance.bookingTitle")}</h3>

      {b && (
        <dl className="mt-2 grid grid-cols-[1fr_auto] gap-y-1 text-sm">
          <dt className="text-muted-foreground">{t("finance.accommodation")}</dt><dd className="text-right">{formatKzt(b.accommodation, lang)}</dd>
          {Number(b.extras) > 0 && (<><dt className="text-muted-foreground">{t("finance.extras")}</dt><dd className="text-right">{formatKzt(b.extras, lang)}</dd></>)}
          {Number(b.procedures ?? 0) > 0 && (<><dt className="text-muted-foreground">{t("finance.procedures")}</dt><dd className="text-right">{formatKzt(b.procedures!, lang)}</dd></>)}
          {seesPayments && (<><dt className="text-muted-foreground">{t("finance.paid")}</dt><dd className="text-right">{formatKzt(b.paid_net, lang)}</dd></>)}
          {seesPayments && (
            <>
              <dt className="font-medium">{due >= 0 ? t("finance.due") : t("finance.overpaid")}</dt>
              <dd className={cn("text-right font-semibold", due > 0 ? "text-destructive" : due < 0 ? "text-warning" : "text-success")}>
                {formatKzt(Math.abs(due), lang)}
              </dd>
            </>
          )}
        </dl>
      )}
      {!active && seesPayments && due < 0 && <p className="mt-1 text-xs text-muted-foreground">{t("finance.cancelledHint")}</p>}

      {(extras.data?.length ?? 0) > 0 && (
        <ul className="mt-3 divide-y rounded-md border text-sm">
          {extras.data!.map((x) => (
            <li key={x.id} className="flex items-center gap-2 px-3 py-1.5">
              <span className="flex-1">{x.name}{Number(x.quantity) !== 1 && <span className="text-muted-foreground"> × {Number(x.quantity)}</span>}</span>
              <span>{formatKzt(x.amount, lang)}</span>
              {canExtras && active && (
                <Button size="icon" variant="ghost" className="h-7 w-7 text-destructive" aria-label={t("common.delete")} onClick={() => removeExtra(x.id)}><Trash2 /></Button>
              )}
            </li>
          ))}
        </ul>
      )}

      {seesPayments && (payments.data?.length ?? 0) > 0 && (
        <ul className="mt-3 divide-y rounded-md border text-sm">
          {payments.data!.map((p) => (
            <li key={p.id} className={cn("px-3 py-1.5", p.voided_at && "text-muted-foreground")}>
              <div className="flex items-center gap-2">
                <span className={cn("flex-1", p.voided_at && "line-through")}>
                  {t(`finance.kind.${p.kind}`)} · {t(`finance.method.${p.method}`)}
                  <span className="ml-2 text-xs text-muted-foreground">{formatDateTime(p.paid_at, lang, org.timezone)}</span>
                </span>
                <span className={cn(p.voided_at && "line-through", p.kind === "refund" && "text-warning")}>
                  {p.kind === "refund" ? "−" : ""}{formatKzt(p.amount, lang)}
                </span>
                {canVoid && !p.voided_at && voiding !== p.id && (
                  <Button size="sm" variant="ghost" className="h-7 text-xs" onClick={() => { setVoiding(p.id); setVoidReason(""); }}>{t("finance.void")}</Button>
                )}
              </div>
              {(p.note || p.void_reason) && (
                <p className="text-xs text-muted-foreground">{p.void_reason ? `${t("finance.voidedBecause")}: ${p.void_reason}` : p.note}</p>
              )}
              {voiding === p.id && (
                <div className="mt-1.5 flex gap-2">
                  <Input className="h-8" placeholder={t("finance.voidReason")} value={voidReason} maxLength={500} onChange={(e) => setVoidReason(e.target.value)} autoFocus />
                  <Button size="sm" variant="destructive" onClick={() => voidPayment(p.id)}>{t("finance.void")}</Button>
                  <Button size="sm" variant="ghost" onClick={() => setVoiding(null)}>{t("common.cancel")}</Button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}

      {mode ? (
        <div className="mt-3 grid gap-2 rounded-md border bg-muted/40 p-3">
          <p className="text-sm font-medium">{t(mode === "extra" ? "finance.addExtra" : mode === "refund" ? "finance.addRefund" : "finance.addPayment")}</p>
          {mode === "extra" ? (
            <div className="grid gap-2 sm:grid-cols-[1fr_80px_120px]">
              <Input placeholder={t("finance.extraName")} aria-label={t("finance.extraName")} value={extraName} maxLength={200} onChange={(e) => setExtraName(e.target.value)} autoFocus />
              <Input inputMode="decimal" aria-label={t("finance.quantity")} value={extraQty} onChange={(e) => setExtraQty(e.target.value)} />
              <Input inputMode="decimal" placeholder={t("finance.unitPrice")} aria-label={t("finance.unitPrice")} value={amount} onChange={(e) => setAmount(e.target.value)} />
            </div>
          ) : (
            <div className="grid gap-2 sm:grid-cols-[140px_1fr]">
              <Input inputMode="decimal" placeholder={t("finance.amount")} aria-label={t("finance.amount")} value={amount} onChange={(e) => setAmount(e.target.value)} autoFocus />
              <NativeSelect value={method} aria-label={t("finance.methodLabel")} onChange={(e) => setMethod(e.target.value as PaymentMethod)}>
                {PAYMENT_METHODS.map((m) => <option key={m} value={m}>{t(`finance.method.${m}`)}</option>)}
              </NativeSelect>
              <Input className="sm:col-span-2" placeholder={mode === "refund" ? t("finance.refundReason") : t("finance.notePlaceholder")}
                value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} />
            </div>
          )}
          <div className="flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={() => setMode(null)}>{t("common.cancel")}</Button>
            <Button size="sm" disabled={busy || (mode === "extra" && !extraName.trim())} onClick={submit}>{busy ? t("common.saving") : t("common.save")}</Button>
          </div>
        </div>
      ) : (
        <div className="mt-3 flex flex-wrap gap-2">
          {canPay && active && <Button size="sm" onClick={() => open("payment")}><Plus /> {t("finance.addPayment")}</Button>}
          {canExtras && active && <Button size="sm" variant="outline" onClick={() => open("extra")}><Plus /> {t("finance.addExtra")}</Button>}
          {canRefund && Number(b?.paid_net ?? 0) > 0 && <Button size="sm" variant="ghost" onClick={() => open("refund")}>{t("finance.addRefund")}</Button>}
        </div>
      )}
    </section>
  );
}
