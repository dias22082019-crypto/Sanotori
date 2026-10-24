import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { formatDate, formatKzPhone, todayInTimeZone, zonedDateTime } from "@/lib/format";
import { addDays } from "@/lib/bookings";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";

type Period = "monthly" | "yearly";

interface AdminPlan {
  id: string;
  code: string;
  name_ru: string;
  name_kk: string;
  price_monthly: string | number;
  price_yearly: string | number;
  is_active: boolean;
}

interface PlanRequest {
  id: string;
  tenant_id: string;
  billing_period: Period;
  note: string | null;
  created_at: string;
  plan: { code: string; name_ru: string; name_kk: string } | null;
}

export interface AdminOrgRef { id: string; name: string; phone: string | null; email: string | null }

const PLATFORM_TZ = "Asia/Almaty";

export function useAdminPlans() {
  return useQuery({
    queryKey: ["admin-plans"],
    queryFn: async () => {
      const { data, error } = await supabase.from("subscription_plans")
        .select("id, code, name_ru, name_kk, price_monthly, price_yearly, is_active").order("sort_order");
      if (error) throw error;
      return data as AdminPlan[];
    },
  });
}

/** Заявки санаториев на тариф. Оплата проходит вне системы; после неё владелец платформы включает тариф. */
export function PlanRequests({ orgs, onActivate }: { orgs: AdminOrgRef[]; onActivate: (org: AdminOrgRef, plan?: string, period?: Period) => void }) {
  const { t, i18n } = useTranslation();
  const lang = i18n.language === "kk" ? "kk" : "ru";
  const requests = useQuery({
    queryKey: ["admin-plan-requests"],
    queryFn: async () => {
      const { data, error } = await supabase.from("plan_change_requests")
        .select("id, tenant_id, billing_period, note, created_at, plan:subscription_plans(code, name_ru, name_kk)")
        .eq("status", "open").order("created_at", { ascending: false });
      if (error) throw error;
      return data as unknown as PlanRequest[];
    },
  });
  const org = (id: string) => orgs.find((o) => o.id === id);

  return (
    <Card className="mt-6">
      <CardHeader>
        <CardTitle>{t("admin.requestsTitle")}</CardTitle>
        <CardDescription>{t("admin.requestsText")}</CardDescription>
      </CardHeader>
      <CardContent>
        {(requests.data?.length ?? 0) === 0 ? <p className="text-sm text-muted-foreground">{t("admin.noRequests")}</p> : (
          <ul className="divide-y text-sm">
            {requests.data!.map((r) => {
              const o = org(r.tenant_id);
              return (
                <li key={r.id} className="flex flex-wrap items-center gap-3 py-2.5">
                  <div className="min-w-0 flex-1">
                    <p className="font-medium">{o?.name ?? "—"} → {r.plan ? (lang === "kk" ? r.plan.name_kk : r.plan.name_ru) : "—"}, {t(`billing.period.${r.billing_period}`)}</p>
                    <p className="text-xs text-muted-foreground">
                      {formatDate(r.created_at, lang)}
                      {o?.phone && ` · ${formatKzPhone(o.phone)}`}
                      {o?.email && ` · ${o.email}`}
                      {r.note && ` · ${r.note}`}
                    </p>
                  </div>
                  {o && <Button size="sm" onClick={() => onActivate(o, r.plan?.code, r.billing_period)}>{t("admin.activate")}</Button>}
                </li>
              );
            })}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}

/** Включение тарифа после оплаты: тариф, период и дата окончания */
export function ActivatePlanDialog({ org, plan, period, onClose }: { org: AdminOrgRef; plan?: string; period?: Period; onClose: () => void }) {
  const { t, i18n } = useTranslation();
  const lang = i18n.language === "kk" ? "kk" : "ru";
  const qc = useQueryClient();
  const plans = useAdminPlans();
  const today = todayInTimeZone(PLATFORM_TZ);
  const [code, setCode] = useState(plan ?? "business");
  const [per, setPer] = useState<Period>(period ?? "monthly");
  const [until, setUntil] = useState(addDays(today, (period ?? "monthly") === "yearly" ? 365 : 30));
  const [busy, setBusy] = useState(false);

  const save = async () => {
    setBusy(true);
    const { error } = await supabase.rpc("admin_set_plan", {
      p_tenant: org.id, p_plan_code: code, p_period: per, p_period_end: zonedDateTime(until, "23:59", PLATFORM_TZ),
    });
    setBusy(false);
    if (error) return toast.error(describeError(error, t));
    toast.success(t("admin.activated"));
    for (const key of ["admin-orgs", "admin-plan-requests"]) void qc.invalidateQueries({ queryKey: [key] });
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("admin.activateTitle", { name: org.name })} description={t("admin.activateText")}>
      <div className="grid gap-4">
        <FormField id="act-plan" label={t("admin.colPlan")}>
          <NativeSelect id="act-plan" value={code} onChange={(e) => setCode(e.target.value)}>
            {plans.data?.filter((p) => p.is_active).map((p) => <option key={p.code} value={p.code}>{lang === "kk" ? p.name_kk : p.name_ru}</option>)}
          </NativeSelect>
        </FormField>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="act-period" label={t("billing.periodLabel")}>
            <NativeSelect id="act-period" value={per} onChange={(e) => {
              const v = e.target.value as Period;
              setPer(v);
              setUntil(addDays(today, v === "yearly" ? 365 : 30));
            }}>
              <option value="monthly">{t("billing.period.monthly")}</option>
              <option value="yearly">{t("billing.period.yearly")}</option>
            </NativeSelect>
          </FormField>
          <FormField id="act-until" label={t("admin.paidUntil")}>
            <Input id="act-until" type="date" min={addDays(today, 1)} value={until} onChange={(e) => setUntil(e.target.value)} />
          </FormField>
        </div>
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy || !until} onClick={save}>{busy ? t("common.saving") : t("admin.activate")}</Button>
      </DialogFooter>
    </Dialog>
  );
}

/** Цены тарифов (в тенге). Меняет только владелец платформы — RLS subscription_plans_admin_update. */
export function PlanPrices() {
  const { t, i18n } = useTranslation();
  const lang = i18n.language === "kk" ? "kk" : "ru";
  const plans = useAdminPlans();
  const qc = useQueryClient();
  const [draft, setDraft] = useState<Record<string, { m: string; y: string }>>({});

  const value = (p: AdminPlan) => draft[p.id] ?? { m: String(Number(p.price_monthly)), y: String(Number(p.price_yearly)) };
  const save = async (p: AdminPlan) => {
    const v = value(p);
    const m = Number(v.m.replace(/\s/g, "")), y = Number(v.y.replace(/\s/g, ""));
    if (!Number.isFinite(m) || !Number.isFinite(y) || m < 0 || y < 0) return toast.error(t("admin.priceInvalid"));
    const { error } = await supabase.from("subscription_plans").update({ price_monthly: m, price_yearly: y }).eq("id", p.id);
    if (error) return toast.error(describeError(error, t));
    toast.success(t("common.saved"));
    setDraft(({ [p.id]: _, ...rest }) => rest);
    void qc.invalidateQueries({ queryKey: ["admin-plans"] });
    void qc.invalidateQueries({ queryKey: ["billing", "plans"] });
  };

  return (
    <Card className="mt-6">
      <CardHeader>
        <CardTitle>{t("admin.pricesTitle")}</CardTitle>
        <CardDescription>{t("admin.pricesText")}</CardDescription>
      </CardHeader>
      <CardContent>
        <ul className="divide-y">
          {plans.data?.map((p) => {
            const v = value(p);
            return (
              <li key={p.id} className="grid items-end gap-3 py-3 sm:grid-cols-[1fr_160px_160px_auto]">
                <span className="text-sm font-medium sm:self-center">{lang === "kk" ? p.name_kk : p.name_ru}</span>
                <FormField id={`pm-${p.id}`} label={t("admin.priceMonthly")}>
                  <Input id={`pm-${p.id}`} inputMode="decimal" value={v.m} onChange={(e) => setDraft({ ...draft, [p.id]: { ...v, m: e.target.value } })} />
                </FormField>
                <FormField id={`py-${p.id}`} label={t("admin.priceYearly")}>
                  <Input id={`py-${p.id}`} inputMode="decimal" value={v.y} onChange={(e) => setDraft({ ...draft, [p.id]: { ...v, y: e.target.value } })} />
                </FormField>
                <Button variant="outline" disabled={!draft[p.id]} onClick={() => save(p)}>{t("common.save")}</Button>
              </li>
            );
          })}
        </ul>
      </CardContent>
    </Card>
  );
}
