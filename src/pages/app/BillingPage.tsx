import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Check } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { formatDate, formatKzt, type AppLanguage } from "@/lib/format";
import type { SubscriptionStatus } from "@/lib/types";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { NativeSelect, Textarea } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorState } from "@/components/states/ErrorState";

type Period = "monthly" | "yearly";

interface Overview {
  plan_code: string;
  plan_name_ru: string;
  plan_name_kk: string;
  status: SubscriptionStatus;
  billing_period: Period;
  trial_ends_at: string | null;
  current_period_end: string | null;
  grace_days: number;
  writable: boolean;
  staff_count: number;
  max_staff: number | null;
  rooms_count: number;
  max_rooms: number | null;
  features: string[];
  open_request: { id: string; plan_code: string; billing_period: Period; created_at: string } | null;
}

interface Plan {
  id: string;
  code: string;
  name_ru: string;
  name_kk: string;
  description_ru: string | null;
  description_kk: string | null;
  price_monthly: string | number;
  price_yearly: string | number;
  max_staff: number | null;
  max_rooms: number | null;
  features: { feature_code: string }[];
}

interface Invoice {
  id: string;
  amount: string | number;
  period_start: string;
  period_end: string;
  status: string;
  is_test: boolean;
  paid_at: string | null;
  created_at: string;
}

/** Модули тарифа в том порядке, в котором их удобно сравнивать */
/** Модули тарифа, которые ещё в разработке: показываем честно, с пометкой «скоро» */
const SOON_FEATURES = new Set(["custom_roles", "branches"]);
const FEATURE_ORDER = ["rooms", "guests", "bookings", "public_site", "finance", "procedures", "tasks", "inventory",
  "analytics", "integrations", "marketing", "custom_roles", "branches"];

/**
 * Подписка санатория (billing.manage). Онлайн-оплаты подписки нет: владелец оставляет заявку,
 * владелец платформы выставляет счёт и включает тариф после оплаты. Экран работает и при истёкшей подписке.
 */
export function BillingPage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const [choosing, setChoosing] = useState<Plan | null>(null);

  const overview = useQuery({
    queryKey: ["billing", org.id, "overview"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("subscription_overview", { p_tenant: org.id });
      if (error) throw error;
      return data as Overview;
    },
  });
  const plans = useQuery({
    queryKey: ["billing", "plans"],
    queryFn: async () => {
      const { data, error } = await supabase.from("subscription_plans")
        .select("id, code, name_ru, name_kk, description_ru, description_kk, price_monthly, price_yearly, max_staff, max_rooms, features:plan_features(feature_code)")
        .order("sort_order");
      if (error) throw error;
      return data as unknown as Plan[];
    },
  });
  const invoices = useQuery({
    queryKey: ["billing", org.id, "invoices"],
    queryFn: async () => {
      const { data, error } = await supabase.from("subscription_invoices")
        .select("id, amount, period_start, period_end, status, is_test, paid_at, created_at")
        .eq("tenant_id", org.id).order("created_at", { ascending: false }).limit(24);
      if (error) throw error;
      return data as Invoice[];
    },
  });

  const cancelRequest = async (id: string) => {
    const { error } = await supabase.rpc("cancel_plan_request", { p_request_id: id });
    if (error) return toast.error(describeError(error, t));
    toast.success(t("billing.requestCancelled"));
    void qc.invalidateQueries({ queryKey: ["billing", org.id] });
  };

  const o = overview.data;
  const planName = (p: { name_ru: string; name_kk: string }) => (lang === "kk" ? p.name_kk : p.name_ru);
  const until = o ? (o.status === "trialing" ? o.trial_ends_at : o.current_period_end) : null;
  const daysLeft = until ? Math.ceil((Date.parse(until) - Date.now()) / 86_400_000) : null;
  const requestedPlan = o?.open_request ? plans.data?.find((p) => p.code === o.open_request!.plan_code) : undefined;

  return (
    <>
      <PageHeader title={t("billing.title")} description={t("billing.subtitle")} />

      {overview.isLoading ? <Skeleton className="h-40" /> : overview.error ? (
        <ErrorState error={overview.error} onRetry={() => overview.refetch()} />
      ) : o && (
        <div className="grid gap-4 lg:grid-cols-[1fr_1fr]">
          <Card>
            <CardHeader>
              <CardDescription>{t("billing.current")}</CardDescription>
              <CardTitle className="flex flex-wrap items-center gap-2 text-2xl">
                {lang === "kk" ? o.plan_name_kk : o.plan_name_ru}
                <Badge variant={o.writable ? "success" : "warning"}>{t(`subscription.status.${o.status}`)}</Badge>
              </CardTitle>
            </CardHeader>
            <CardContent className="grid gap-2 text-sm">
              {until && (
                <p>
                  {t(o.status === "trialing" ? "billing.trialUntil" : "billing.paidUntil", { date: formatDate(until, lang) })}
                  {daysLeft !== null && daysLeft >= 0 && <span className="text-muted-foreground"> · {t("billing.daysLeft", { count: daysLeft })}</span>}
                </p>
              )}
              {o.status === "past_due" && <p className="text-warning">{t("billing.graceNote", { count: o.grace_days })}</p>}
              {!o.writable && <p className="text-warning">{t("billing.readOnlyNote")}</p>}
              <Usage label={t("billing.staff")} used={o.staff_count} max={o.max_staff} />
              <Usage label={t("billing.rooms")} used={o.rooms_count} max={o.max_rooms} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>{t("billing.howTitle")}</CardTitle>
              <CardDescription>{t("billing.howText")}</CardDescription>
            </CardHeader>
            <CardContent className="text-sm">
              {o.open_request ? (
                <div className="rounded-md border border-primary/30 bg-primary/5 p-3">
                  <p className="font-medium">
                    {t("billing.requestOpen", {
                      plan: requestedPlan ? planName(requestedPlan) : o.open_request.plan_code,
                      period: t(`billing.period.${o.open_request.billing_period}`),
                    })}
                  </p>
                  <p className="mt-0.5 text-xs text-muted-foreground">{t("billing.requestSent", { date: formatDate(o.open_request.created_at, lang) })}</p>
                  <Button size="sm" variant="ghost" className="mt-2 h-7 px-2" onClick={() => cancelRequest(o.open_request!.id)}>{t("billing.cancelRequest")}</Button>
                </div>
              ) : (
                <p className="text-muted-foreground">{t("billing.noRequest")}</p>
              )}
            </CardContent>
          </Card>
        </div>
      )}

      <h2 className="mb-3 mt-8 text-lg font-semibold">{t("billing.plansTitle")}</h2>
      {plans.isLoading ? <Skeleton className="h-60" /> : plans.error ? <ErrorState error={plans.error} onRetry={() => plans.refetch()} /> : (
        <div className="grid gap-4 md:grid-cols-3">
          {plans.data!.map((p) => {
            const current = o?.plan_code === p.code;
            const codes = new Set(p.features.map((f) => f.feature_code));
            const priced = Number(p.price_monthly) > 0 || Number(p.price_yearly) > 0;
            return (
              <Card key={p.id} className={cn("flex flex-col", current && "border-primary ring-1 ring-primary")}>
                <CardHeader>
                  <CardTitle className="flex items-center justify-between gap-2">
                    {planName(p)}
                    {current && <Badge>{t("billing.yourPlan")}</Badge>}
                  </CardTitle>
                  {(lang === "kk" ? p.description_kk : p.description_ru) && (
                    <CardDescription>{lang === "kk" ? p.description_kk : p.description_ru}</CardDescription>
                  )}
                </CardHeader>
                <CardContent className="flex flex-1 flex-col gap-3 text-sm">
                  {priced ? (
                    <div>
                      <p className="text-xl font-semibold">{formatKzt(p.price_monthly, lang)} <span className="text-sm font-normal text-muted-foreground">{t("billing.perMonth")}</span></p>
                      {Number(p.price_yearly) > 0 && <p className="text-xs text-muted-foreground">{formatKzt(p.price_yearly, lang)} {t("billing.perYear")}</p>}
                    </div>
                  ) : (
                    <p className="text-muted-foreground">{t("billing.priceOnRequest")}</p>
                  )}
                  <p className="text-xs text-muted-foreground">
                    {t("billing.limitStaff", { value: p.max_staff ?? t("billing.unlimited") })} · {t("billing.limitRooms", { value: p.max_rooms ?? t("billing.unlimited") })}
                  </p>
                  <ul className="grid gap-1">
                    {FEATURE_ORDER.filter((f) => codes.has(f)).map((f) => (
                      <li key={f} className="flex items-center gap-2"><Check className="h-3.5 w-3.5 text-success" />{t(`billing.features.${f}`)}
                        {SOON_FEATURES.has(f) && <Badge variant="outline" className="text-[10px] font-normal text-muted-foreground">{t("billing.soon")}</Badge>}</li>
                    ))}
                  </ul>
                  <div className="mt-auto pt-2">
                    <Button className="w-full" variant={current ? "outline" : "default"} onClick={() => setChoosing(p)}>
                      {current ? t("billing.renew") : t("billing.choose")}
                    </Button>
                  </div>
                </CardContent>
              </Card>
            );
          })}
        </div>
      )}

      {(invoices.data?.length ?? 0) > 0 && (
        <Card className="mt-8">
          <CardHeader><CardTitle>{t("billing.invoicesTitle")}</CardTitle></CardHeader>
          <CardContent>
            <ul className="divide-y text-sm">
              {invoices.data!.map((inv) => (
                <li key={inv.id} className="flex flex-wrap items-center gap-3 py-2">
                  <span className="flex-1">{formatDate(inv.period_start, lang)} — {formatDate(inv.period_end, lang)}</span>
                  {inv.is_test && <Badge variant="secondary">{t("billing.test")}</Badge>}
                  <Badge variant={inv.status === "paid" ? "success" : "warning"}>{t(`billing.invoiceStatus.${inv.status}`, { defaultValue: inv.status })}</Badge>
                  <span className="w-28 text-right tabular-nums">{formatKzt(inv.amount, lang)}</span>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}

      {choosing && <RequestDialog plan={choosing} name={planName(choosing)} onClose={() => setChoosing(null)} />}
    </>
  );
}

function Usage({ label, used, max }: { label: string; used: number; max: number | null }) {
  const { t } = useTranslation();
  const pct = max ? Math.min(100, Math.round((used / max) * 100)) : 0;
  return (
    <div className="mt-1">
      <div className="flex justify-between text-xs">
        <span className="text-muted-foreground">{label}</span>
        <span className="tabular-nums">{max ? `${used} / ${max}` : `${used} · ${t("billing.unlimited")}`}</span>
      </div>
      {max !== null && (
        <div className="mt-1 h-1.5 overflow-hidden rounded-full bg-muted">
          <div className={cn("h-full rounded-full", pct >= 90 ? "bg-destructive" : "bg-primary")} style={{ width: `${pct}%` }} />
        </div>
      )}
    </div>
  );
}

function RequestDialog({ plan, name, onClose }: { plan: Plan; name: string; onClose: () => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const [period, setPeriod] = useState<Period>("monthly");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const price = period === "yearly" ? plan.price_yearly : plan.price_monthly;

  const send = async () => {
    setBusy(true);
    const { error } = await supabase.rpc("request_plan_change", { p_tenant: org.id, p_plan_code: plan.code, p_period: period, p_note: note || null });
    setBusy(false);
    if (error) return toast.error(describeError(error, t));
    toast.success(t("billing.requestDone"));
    void qc.invalidateQueries({ queryKey: ["billing", org.id] });
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("billing.requestTitle", { plan: name })} description={t("billing.requestText")}>
      <div className="grid gap-4">
        <FormField id="req-period" label={t("billing.periodLabel")}
          hint={Number(price) > 0 ? `${formatKzt(price, lang)} ${t(period === "yearly" ? "billing.perYear" : "billing.perMonth")}` : t("billing.priceOnRequest")}>
          <NativeSelect id="req-period" value={period} onChange={(e) => setPeriod(e.target.value as Period)}>
            <option value="monthly">{t("billing.period.monthly")}</option>
            <option value="yearly">{t("billing.period.yearly")}</option>
          </NativeSelect>
        </FormField>
        <FormField id="req-note" label={t("billing.noteLabel")} hint={t("billing.noteHint")}>
          <Textarea id="req-note" rows={3} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} />
        </FormField>
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy} onClick={send}>{busy ? t("common.saving") : t("billing.send")}</Button>
      </DialogFooter>
    </Dialog>
  );
}
