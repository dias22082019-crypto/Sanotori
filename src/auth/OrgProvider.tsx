import { createContext, useContext, useEffect, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { Navigate, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { supabase } from "@/lib/supabase";
import type { MyOrganization, Organization, OrganizationSubscription, Permission } from "@/lib/types";
import { hasSavedLanguage } from "@/i18n";
import { LoadingScreen } from "@/components/states/LoadingScreen";
import { ErrorState } from "@/components/states/ErrorState";

interface OrgState {
  org: Organization;
  membership: MyOrganization;
  permissions: Set<Permission>;
  subscription: OrganizationSubscription | null;
  /** Подписка позволяет изменять данные (совпадает с app.subscription_writable в БД) */
  writable: boolean;
  can: (permission: Permission) => boolean;
}

const OrgContext = createContext<OrgState | null>(null);

export function isSubscriptionWritable(s: OrganizationSubscription | null, now = Date.now()): boolean {
  if (!s) return false;
  const ts = (v: string | null) => (v ? Date.parse(v) : NaN);
  if (s.status === "trialing") return ts(s.trial_ends_at) > now;
  if (s.status === "active") return !s.current_period_end || ts(s.current_period_end) > now;
  if (s.status === "past_due") {
    const end = ts(s.current_period_end ?? s.trial_ends_at);
    return end + s.grace_days * 86_400_000 > now;
  }
  return false;
}

export const myOrganizationsQuery = {
  queryKey: ["my-organizations"],
  queryFn: async (): Promise<MyOrganization[]> => {
    const { data, error } = await supabase.rpc("my_organizations");
    if (error) throw error;
    return (data ?? []) as MyOrganization[];
  },
};

/** Загружает организацию из URL (/app/:orgSlug) и права текущего пользователя в ней */
export function OrgProvider({ children }: { children: ReactNode }) {
  const { orgSlug } = useParams();
  const { i18n } = useTranslation();
  const orgs = useQuery(myOrganizationsQuery);
  const membership = orgs.data?.find((o) => o.slug === orgSlug);

  const details = useQuery({
    queryKey: ["org", membership?.tenant_id],
    enabled: Boolean(membership),
    queryFn: async () => {
      const tenantId = membership!.tenant_id;
      const [orgRes, permRes, subRes] = await Promise.all([
        supabase.from("organizations").select("*").eq("id", tenantId).single(),
        supabase.rpc("my_permissions", { p_tenant: tenantId }),
        supabase
          .from("organization_subscriptions")
          .select("id, status, trial_ends_at, current_period_end, grace_days, plan:subscription_plans(code, name_ru, name_kk)")
          .eq("tenant_id", tenantId)
          .neq("status", "cancelled")
          .maybeSingle(),
      ]);
      if (orgRes.error) throw orgRes.error;
      if (permRes.error) throw permRes.error;
      if (subRes.error) throw subRes.error;
      return {
        org: orgRes.data as Organization,
        permissions: new Set((permRes.data ?? []) as Permission[]),
        subscription: subRes.data as unknown as OrganizationSubscription | null,
      };
    },
  });

  const orgLanguage = details.data?.org.default_language;
  useEffect(() => {
    if (orgLanguage && !hasSavedLanguage() && i18n.language !== orgLanguage) void i18n.changeLanguage(orgLanguage);
  }, [orgLanguage, i18n]);

  if (orgs.isLoading || (membership && details.isLoading)) return <LoadingScreen />;
  if (orgs.error) return <ErrorState error={orgs.error} onRetry={() => orgs.refetch()} />;
  if (!membership) return <Navigate to="/select-org" replace />;
  if (details.error || !details.data) return <ErrorState error={details.error} onRetry={() => details.refetch()} />;

  const { org, permissions, subscription } = details.data;
  const value: OrgState = {
    org,
    membership,
    permissions,
    subscription,
    writable: isSubscriptionWritable(subscription),
    can: (p) => permissions.has(p),
  };
  return <OrgContext.Provider value={value}>{children}</OrgContext.Provider>;
}

export function useOrg(): OrgState {
  const ctx = useContext(OrgContext);
  if (!ctx) throw new Error("useOrg must be used inside OrgProvider");
  return ctx;
}
