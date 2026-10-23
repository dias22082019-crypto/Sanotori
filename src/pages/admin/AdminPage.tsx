import { Link, Navigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ShieldCheck } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { formatDate } from "@/lib/format";
import type { OrganizationSubscription, SubscriptionStatus } from "@/lib/types";
import { isSubscriptionWritable } from "@/auth/OrgProvider";
import { usePlatformAdminQuery } from "@/layouts/AppLayout";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { LanguageSwitcher } from "@/components/LanguageSwitcher";
import { Logo } from "@/components/Logo";
import { LoadingScreen } from "@/components/states/LoadingScreen";
import { ErrorState } from "@/components/states/ErrorState";

interface AdminOrgRow {
  id: string;
  name: string;
  slug: string;
  city: string | null;
  created_at: string;
  subscription: OrganizationSubscription[];
}

/**
 * Панель владельца платформы. RLS отдаёт super_admin только организации и подписки:
 * гости, сотрудники и медицинские данные санаториев здесь недоступны по определению.
 */
export function AdminPage() {
  const { t, i18n } = useTranslation();
  const adminQuery = usePlatformAdminQuery();
  const isAdmin = adminQuery.data === true;
  const queryClient = useQueryClient();
  const lang = i18n.language === "kk" ? "kk" : "ru";

  const orgs = useQuery({
    queryKey: ["admin-orgs"],
    enabled: isAdmin,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("organizations")
        .select("id, name, slug, city, created_at, subscription:organization_subscriptions(id, status, trial_ends_at, current_period_end, grace_days, plan:subscription_plans(code, name_ru, name_kk))")
        .order("created_at", { ascending: false });
      if (error) throw error;
      return data as unknown as AdminOrgRow[];
    },
  });

  const setStatus = useMutation({
    mutationFn: async ({ tenant, status }: { tenant: string; status: SubscriptionStatus }) => {
      const { error } = await supabase.rpc("admin_set_subscription_status", { p_tenant: tenant, p_status: status });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(t("common.saved")); void queryClient.invalidateQueries({ queryKey: ["admin-orgs"] }); },
    onError: (e) => toast.error(describeError(e, t)),
  });

  if (adminQuery.isLoading) return <LoadingScreen />;
  if (!isAdmin) return <Navigate to="/select-org" replace />;

  const rows = orgs.data ?? [];
  const current = (r: AdminOrgRow) => r.subscription.find((s) => s.status !== "cancelled") ?? null;

  return (
    <div className="min-h-screen">
      <header className="flex h-14 items-center justify-between border-b bg-card px-4">
        <Link to="/select-org"><Logo /></Link>
        <LanguageSwitcher />
      </header>
      <main className="mx-auto max-w-6xl px-4 py-6">
        <h1 className="text-2xl font-semibold">{t("admin.title")}</h1>
        <p className="mt-2 flex items-center gap-2 text-sm text-muted-foreground"><ShieldCheck className="h-4 w-4 text-primary" />{t("admin.privacyNote")}</p>

        {orgs.isLoading ? <LoadingScreen /> : orgs.error ? <ErrorState error={orgs.error} onRetry={() => orgs.refetch()} /> : (
          <>
            <div className="mt-6 grid grid-cols-2 gap-4 sm:max-w-md">
              <Card><CardContent className="pt-5"><p className="text-sm text-muted-foreground">{t("admin.statsOrgs")}</p><p className="text-2xl font-semibold">{rows.length}</p></CardContent></Card>
              <Card><CardContent className="pt-5"><p className="text-sm text-muted-foreground">{t("admin.statsActive")}</p><p className="text-2xl font-semibold">{rows.filter((r) => isSubscriptionWritable(current(r))).length}</p></CardContent></Card>
            </div>
            <Card className="mt-6">
              <CardHeader><CardTitle>{t("admin.orgsTitle")}</CardTitle></CardHeader>
              <CardContent>
                {rows.length === 0 ? <p className="text-sm text-muted-foreground">{t("admin.empty")}</p> : (
                  <div className="-mx-5 overflow-x-auto">
                    <table className="w-full min-w-[720px] text-sm">
                      <thead>
                        <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
                          <th className="px-5 py-2 font-medium">{t("admin.colOrg")}</th>
                          <th className="px-5 py-2 font-medium">{t("admin.colCity")}</th>
                          <th className="px-5 py-2 font-medium">{t("admin.colPlan")}</th>
                          <th className="px-5 py-2 font-medium">{t("admin.colStatus")}</th>
                          <th className="px-5 py-2 font-medium">{t("admin.colCreated")}</th>
                          <th className="px-5 py-2" />
                        </tr>
                      </thead>
                      <tbody className="divide-y">
                        {rows.map((r) => {
                          const sub = current(r);
                          return (
                            <tr key={r.id}>
                              <td className="px-5 py-2.5"><span className="font-medium">{r.name}</span><span className="block text-xs text-muted-foreground">/s/{r.slug}</span></td>
                              <td className="px-5 py-2.5">{r.city ?? "—"}</td>
                              <td className="px-5 py-2.5">{sub?.plan ? (lang === "kk" ? sub.plan.name_kk : sub.plan.name_ru) : "—"}</td>
                              <td className="px-5 py-2.5">
                                {sub ? <Badge variant={isSubscriptionWritable(sub) ? "success" : "warning"}>{t(`subscription.status.${sub.status}`)}</Badge> : "—"}
                                {sub?.status === "trialing" && sub.trial_ends_at && <span className="ml-2 text-xs text-muted-foreground">{formatDate(sub.trial_ends_at, lang)}</span>}
                              </td>
                              <td className="px-5 py-2.5">{formatDate(r.created_at, lang)}</td>
                              <td className="px-5 py-2.5 text-right">
                                {sub && (sub.status === "suspended" ? (
                                  <Button size="sm" variant="outline" onClick={() => setStatus.mutate({ tenant: r.id, status: "active" })}>{t("admin.resume")}</Button>
                                ) : (
                                  <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setStatus.mutate({ tenant: r.id, status: "suspended" })}>{t("admin.suspend")}</Button>
                                ))}
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                )}
              </CardContent>
            </Card>
          </>
        )}
      </main>
    </div>
  );
}
