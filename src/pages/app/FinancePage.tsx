import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Download, Plus, Wallet } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { formatDate, formatDateTime, formatKzt, todayInTimeZone, zonedDateTime, type AppLanguage } from "@/lib/format";
import { addDays } from "@/lib/bookings";
import {
  PAYMENT_METHODS, describeFinanceError, downloadCsv, monthBounds, parseAmount,
  type Expense, type ExpenseCategory, type FinanceReport, type PaymentKind, type PaymentMethod,
} from "@/lib/finance";
import { cn } from "@/lib/utils";
import { useAuth } from "@/auth/AuthProvider";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorState } from "@/components/states/ErrorState";

/** Начало дня YYYY-MM-DD в часовом поясе санатория как ISO-время со смещением */
export function zonedDayStart(isoDate: string, timeZone: string): string {
  return zonedDateTime(isoDate, "00:00", timeZone);
}

interface PaymentRow {
  id: string;
  kind: PaymentKind;
  method: PaymentMethod;
  amount: string | number;
  paid_at: string;
  note: string | null;
  voided_at: string | null;
  void_reason: string | null;
  booking: { number: number; guest: { full_name: string } | null } | null;
}

/** Финансы: касса за период, оплаты, расходы, должники, выгрузка в CSV */
export function FinancePage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable } = useOrg();
  const today = todayInTimeZone(org.timezone);
  const [month, setMonth] = useState(today.slice(0, 7));
  const { from, to } = monthBounds(`${month}-01`);
  const canWrite = can("finance.write") && writable;

  const report = useQuery({
    queryKey: ["finance", org.id, "report", from, to],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("finance_report", { p_tenant: org.id, p_from: from, p_to: to });
      if (error) throw error;
      return data as FinanceReport;
    },
  });
  const payments = useQuery({
    queryKey: ["finance", org.id, "payments", from, to],
    queryFn: async () => {
      const { data, error } = await supabase.from("booking_payments")
        .select("id, kind, method, amount, paid_at, note, voided_at, void_reason, booking:bookings(number, guest:guests(full_name))")
        .eq("tenant_id", org.id)
        .gte("paid_at", zonedDayStart(from, org.timezone)).lt("paid_at", zonedDayStart(addDays(to, 1), org.timezone))
        .order("paid_at", { ascending: false }).limit(1000);
      if (error) throw error;
      return data as unknown as PaymentRow[];
    },
  });
  const categories = useQuery({
    queryKey: ["finance", org.id, "categories"],
    queryFn: async () => {
      const { data, error } = await supabase.from("expense_categories").select("id, name, is_active").eq("tenant_id", org.id).order("name");
      if (error) throw error;
      return data as ExpenseCategory[];
    },
  });
  const expenses = useQuery({
    queryKey: ["finance", org.id, "expenses", from, to],
    queryFn: async () => {
      const { data, error } = await supabase.from("expenses").select("*").eq("tenant_id", org.id)
        .gte("spent_on", from).lte("spent_on", to).order("spent_on", { ascending: false }).limit(1000);
      if (error) throw error;
      return data as Expense[];
    },
  });
  const debtors = useQuery({
    queryKey: ["finance", org.id, "debtors"],
    queryFn: async () => {
      const { data: bal, error } = await supabase.from("booking_balances").select("booking_id, balance").eq("tenant_id", org.id).gt("balance", 0);
      if (error) throw error;
      if (!bal?.length) return [];
      const { data: rows, error: e2 } = await supabase.from("bookings")
        .select("id, number, check_in, check_out, status, guest:guests(full_name, phone)")
        .in("id", bal.map((b) => b.booking_id as string)).in("status", ["confirmed", "checked_in", "checked_out"])
        .order("check_in");
      if (e2) throw e2;
      const due = new Map(bal.map((b) => [b.booking_id as string, Number(b.balance)]));
      return (rows ?? []).map((r) => ({ ...(r as unknown as { id: string; number: number; check_in: string; check_out: string; status: string; guest: { full_name: string } | null }), due: due.get(r.id as string) ?? 0 }));
    },
  });

  const catName = (id: string) => categories.data?.find((c) => c.id === id)?.name ?? "—";
  const r = report.data;
  const net = r ? Number(r.payments) - Number(r.refunds) - Number(r.expenses) : 0;

  const exportPayments = () => downloadCsv(`payments_${month}.csv`, [
    [t("finance.csv.date"), t("finance.csv.booking"), t("finance.csv.guest"), t("finance.csv.kind"), t("finance.csv.method"), t("finance.csv.amount"), t("finance.csv.note"), t("finance.csv.voided")],
    ...(payments.data ?? []).map((p) => [
      formatDateTime(p.paid_at, lang, org.timezone), p.booking?.number ?? "", p.booking?.guest?.full_name ?? "",
      t(`finance.kind.${p.kind}`), t(`finance.method.${p.method}`), (p.kind === "refund" ? -1 : 1) * Number(p.amount),
      p.note, p.voided_at ? p.void_reason : "",
    ]),
  ]);
  const exportExpenses = () => downloadCsv(`expenses_${month}.csv`, [
    [t("finance.csv.date"), t("finance.csv.category"), t("finance.csv.amount"), t("finance.csv.method"), t("finance.csv.vendor"), t("finance.csv.note"), t("finance.csv.voided")],
    ...(expenses.data ?? []).map((e) => [
      formatDate(e.spent_on, lang), catName(e.category_id), Number(e.amount), t(`finance.method.${e.method}`), e.vendor, e.note, e.voided_at ? e.void_reason : "",
    ]),
  ]);

  return (
    <>
      <PageHeader
        title={t("finance.title")}
        description={t("finance.subtitle")}
        actions={
          <Input type="month" className="w-44" value={month} max={today.slice(0, 7)} aria-label={t("finance.period")}
            onChange={(e) => e.target.value && setMonth(e.target.value)} />
        }
      />

      {report.error ? <ErrorState error={report.error} onRetry={() => report.refetch()} /> : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          {[
            { key: "income", value: r?.payments },
            { key: "refunds", value: r?.refunds },
            { key: "expenses", value: r?.expenses },
            { key: "net", value: r ? net : undefined, tone: net < 0 ? "text-destructive" : "text-success" },
            { key: "receivables", value: r?.receivables, note: t("finance.receivablesNote") },
          ].map((tile) => (
            <Card key={tile.key}>
              <CardContent className="pt-5">
                <p className="text-sm text-muted-foreground">{t(`finance.tiles.${tile.key}`)}</p>
                {tile.value === undefined ? <Skeleton className="mt-2 h-7 w-24" /> : (
                  <p className={cn("mt-2 text-xl font-semibold tabular-nums", tile.tone)}>{formatKzt(tile.value, lang)}</p>
                )}
                {tile.note && <p className="mt-0.5 text-xs text-muted-foreground">{tile.note}</p>}
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      <div className="mt-4 grid gap-4 lg:grid-cols-[1fr_320px]">
        <Card className="min-w-0">
          <CardHeader className="flex-row items-start justify-between gap-2 space-y-0">
            <div>
              <CardTitle>{t("finance.paymentsTitle")}</CardTitle>
              <CardDescription>{t("finance.paymentsText")}</CardDescription>
            </div>
            <Button size="sm" variant="outline" disabled={!payments.data?.length} onClick={exportPayments}><Download /> CSV</Button>
          </CardHeader>
          <CardContent>
            {payments.isLoading ? <Skeleton className="h-24" /> : payments.error ? <ErrorState error={payments.error} onRetry={() => payments.refetch()} /> :
              payments.data!.length === 0 ? <p className="text-sm text-muted-foreground">{t("finance.noPayments")}</p> : (
                <div className="-mx-5 max-h-[420px] overflow-auto">
                  <table className="w-full min-w-[560px] text-sm">
                    <tbody className="divide-y">
                      {payments.data!.map((p) => (
                        <tr key={p.id} className={cn(p.voided_at && "text-muted-foreground line-through")}>
                          <td className="px-5 py-2 whitespace-nowrap">{formatDateTime(p.paid_at, lang, org.timezone)}</td>
                          <td className="px-2 py-2">№{p.booking?.number} · {p.booking?.guest?.full_name}</td>
                          <td className="px-2 py-2">{t(`finance.method.${p.method}`)}</td>
                          <td className={cn("px-5 py-2 text-right whitespace-nowrap", p.kind === "refund" && "text-warning")}>
                            {p.kind === "refund" ? "−" : ""}{formatKzt(p.amount, lang)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle>{t("finance.byMethod")}</CardTitle></CardHeader>
          <CardContent>
            {!r ? <Skeleton className="h-24" /> : (
              <dl className="grid grid-cols-[1fr_auto] gap-y-1.5 text-sm">
                {PAYMENT_METHODS.map((m) => (
                  <div key={m} className="contents">
                    <dt className="text-muted-foreground">{t(`finance.method.${m}`)}</dt>
                    <dd className="text-right tabular-nums">{formatKzt(r.by_method[m] ?? 0, lang)}</dd>
                  </div>
                ))}
              </dl>
            )}
            <p className="mt-3 text-xs text-muted-foreground">{t("finance.kaspiNote")}</p>
          </CardContent>
        </Card>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <ExpensesCard
          month={month} canWrite={canWrite} categories={categories.data ?? []} expenses={expenses.data}
          loading={expenses.isLoading} error={expenses.error} onRetry={() => expenses.refetch()} catName={catName} onExport={exportExpenses}
          byCategory={r?.expenses_by_category ?? []} lang={lang} defaultDate={today < to ? today : to}
        />
        <Card>
          <CardHeader>
            <CardTitle>{t("finance.debtorsTitle")}</CardTitle>
            <CardDescription>{t("finance.debtorsText")}</CardDescription>
          </CardHeader>
          <CardContent>
            {debtors.isLoading ? <Skeleton className="h-24" /> : debtors.error ? <ErrorState error={debtors.error} onRetry={() => debtors.refetch()} /> :
              debtors.data!.length === 0 ? <p className="text-sm text-muted-foreground">{t("finance.noDebtors")}</p> : (
                <ul className="divide-y text-sm">
                  {debtors.data!.map((d) => (
                    <li key={d.id} className="flex items-center gap-3 py-2">
                      <div className="flex-1">
                        <p className="font-medium">№{d.number} · {d.guest?.full_name}</p>
                        <p className="text-xs text-muted-foreground">{formatDate(d.check_in, lang)} — {formatDate(d.check_out, lang)} · {t(`bookings.status.${d.status}`)}</p>
                      </div>
                      <span className="font-medium text-destructive">{formatKzt(d.due, lang)}</span>
                    </li>
                  ))}
                </ul>
              )}
          </CardContent>
        </Card>
      </div>
    </>
  );
}

function ExpensesCard(props: {
  month: string;
  canWrite: boolean;
  categories: ExpenseCategory[];
  expenses: Expense[] | undefined;
  loading: boolean;
  error: unknown;
  onRetry: () => void;
  catName: (id: string) => string;
  onExport: () => void;
  byCategory: { name: string; amount: number }[];
  lang: AppLanguage;
  defaultDate: string;
}) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const { user } = useAuth();
  const qc = useQueryClient();
  const [adding, setAdding] = useState(false);
  const [categoryId, setCategoryId] = useState("");
  const [newCategory, setNewCategory] = useState("");
  const [amount, setAmount] = useState("");
  const [spentOn, setSpentOn] = useState(props.defaultDate);
  const [method, setMethod] = useState<PaymentMethod>("cash");
  const [vendor, setVendor] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [voiding, setVoiding] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const refresh = () => void qc.invalidateQueries({ queryKey: ["finance", org.id] });

  const save = async () => {
    const value = parseAmount(amount);
    if (value === null) return toast.error(t("finance.errors.amount"));
    setBusy(true);
    let catId = categoryId;
    if (catId === "__new") {
      const { data, error } = await supabase.from("expense_categories").insert({ tenant_id: org.id, name: newCategory.trim() }).select("id").single();
      if (error) { setBusy(false); return toast.error(describeFinanceError(error, t)); }
      catId = data.id as string;
    }
    const { error } = await supabase.from("expenses").insert({
      tenant_id: org.id, category_id: catId, amount: value, spent_on: spentOn, method,
      vendor: vendor.trim() || null, note: note.trim() || null, created_by: user?.id,
    });
    setBusy(false);
    if (error) return toast.error(describeFinanceError(error, t));
    toast.success(t("finance.expenseAdded"));
    setAdding(false);
    setAmount(""); setVendor(""); setNote(""); setNewCategory(""); setCategoryId(catId);
    refresh();
  };

  const voidExpense = async (id: string) => {
    if (!reason.trim()) return toast.error(t("finance.errors.reasonRequired"));
    const { error } = await supabase.rpc("void_expense", { p_expense_id: id, p_reason: reason });
    if (error) return toast.error(describeFinanceError(error, t));
    toast.success(t("finance.voided"));
    setVoiding(null); setReason("");
    refresh();
  };

  const activeCats = props.categories.filter((c) => c.is_active);
  return (
    <Card>
      <CardHeader className="flex-row items-start justify-between gap-2 space-y-0">
        <div>
          <CardTitle>{t("finance.expensesTitle")}</CardTitle>
          {props.byCategory.length > 0 && (
            <CardDescription>{props.byCategory.map((c) => `${c.name}: ${formatKzt(c.amount, props.lang)}`).join(" · ")}</CardDescription>
          )}
        </div>
        <div className="flex gap-2">
          <Button size="sm" variant="outline" disabled={!props.expenses?.length} onClick={props.onExport}><Download /> CSV</Button>
          {props.canWrite && !adding && (
            <Button size="sm" onClick={() => { setAdding(true); setCategoryId(activeCats[0]?.id ?? "__new"); setSpentOn(props.defaultDate); }}><Plus /> {t("finance.addExpense")}</Button>
          )}
        </div>
      </CardHeader>
      <CardContent>
        {adding && (
          <div className="mb-4 grid gap-3 rounded-md border bg-muted/40 p-3 sm:grid-cols-2">
            <FormField id="exp-cat" label={t("finance.category")}>
              <NativeSelect id="exp-cat" value={categoryId} onChange={(e) => setCategoryId(e.target.value)}>
                {activeCats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                <option value="__new">{t("finance.newCategory")}</option>
              </NativeSelect>
            </FormField>
            {categoryId === "__new" ? (
              <FormField id="exp-newcat" label={t("finance.newCategoryName")}>
                <Input id="exp-newcat" value={newCategory} maxLength={120} placeholder={t("finance.categoryPlaceholder")} onChange={(e) => setNewCategory(e.target.value)} />
              </FormField>
            ) : <div className="hidden sm:block" />}
            <FormField id="exp-amount" label={t("finance.amount")}>
              <Input id="exp-amount" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
            </FormField>
            <FormField id="exp-date" label={t("finance.date")}>
              <Input id="exp-date" type="date" value={spentOn} onChange={(e) => setSpentOn(e.target.value)} />
            </FormField>
            <FormField id="exp-method" label={t("finance.methodLabel")}>
              <NativeSelect id="exp-method" value={method} onChange={(e) => setMethod(e.target.value as PaymentMethod)}>
                {PAYMENT_METHODS.map((m) => <option key={m} value={m}>{t(`finance.method.${m}`)}</option>)}
              </NativeSelect>
            </FormField>
            <FormField id="exp-vendor" label={`${t("finance.vendor")} (${t("common.optional")})`}>
              <Input id="exp-vendor" value={vendor} maxLength={200} onChange={(e) => setVendor(e.target.value)} />
            </FormField>
            <FormField id="exp-note" label={`${t("finance.note")} (${t("common.optional")})`} className="sm:col-span-2">
              <Input id="exp-note" value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} />
            </FormField>
            <div className="flex justify-end gap-2 sm:col-span-2">
              <Button size="sm" variant="ghost" onClick={() => setAdding(false)}>{t("common.cancel")}</Button>
              <Button size="sm" disabled={busy || !spentOn || (categoryId === "__new" && !newCategory.trim())} onClick={save}>
                {busy ? t("common.saving") : t("common.save")}
              </Button>
            </div>
          </div>
        )}
        {props.loading ? <Skeleton className="h-24" /> : props.error ? <ErrorState error={props.error} onRetry={props.onRetry} /> :
          !props.expenses?.length ? (
            <div className="flex items-center gap-2 text-sm text-muted-foreground"><Wallet className="h-4 w-4" />{t("finance.noExpenses")}</div>
          ) : (
            <ul className="max-h-[420px] divide-y overflow-auto text-sm">
              {props.expenses.map((e) => (
                <li key={e.id} className={cn("py-2", e.voided_at && "text-muted-foreground")}>
                  <div className="flex items-center gap-3">
                    <div className={cn("flex-1", e.voided_at && "line-through")}>
                      <p>{props.catName(e.category_id)}{e.vendor && <span className="text-muted-foreground"> · {e.vendor}</span>}</p>
                      <p className="text-xs text-muted-foreground">{formatDate(e.spent_on, props.lang)} · {t(`finance.method.${e.method}`)}{e.note ? ` · ${e.note}` : ""}</p>
                    </div>
                    <span className={cn("tabular-nums", e.voided_at && "line-through")}>{formatKzt(e.amount, props.lang)}</span>
                    {props.canWrite && !e.voided_at && voiding !== e.id && (
                      <Button size="sm" variant="ghost" className="h-7 text-xs" onClick={() => { setVoiding(e.id); setReason(""); }}>{t("finance.void")}</Button>
                    )}
                  </div>
                  {e.voided_at && <p className="text-xs">{t("finance.voidedBecause")}: {e.void_reason}</p>}
                  {voiding === e.id && (
                    <div className="mt-1.5 flex gap-2">
                      <Input className="h-8" placeholder={t("finance.voidReason")} value={reason} maxLength={500} onChange={(ev) => setReason(ev.target.value)} autoFocus />
                      <Button size="sm" variant="destructive" onClick={() => voidExpense(e.id)}>{t("finance.void")}</Button>
                      <Button size="sm" variant="ghost" onClick={() => setVoiding(null)}>{t("common.cancel")}</Button>
                    </div>
                  )}
                </li>
              ))}
            </ul>
          )}
      </CardContent>
    </Card>
  );
}
