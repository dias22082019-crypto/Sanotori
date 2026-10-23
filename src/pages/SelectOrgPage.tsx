import { Link, Navigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { Building2, ChevronRight, Plus } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { myOrganizationsQuery } from "@/auth/OrgProvider";
import { AuthLayout } from "@/layouts/AuthLayout";
import { LoadingScreen } from "@/components/states/LoadingScreen";
import { ErrorState } from "@/components/states/ErrorState";

/** Выбор организации. Один санаторий — сразу в него; ни одного — на создание. */
export function SelectOrgPage() {
  const { t, i18n } = useTranslation();
  const orgs = useQuery(myOrganizationsQuery);
  const roles = useQuery({
    queryKey: ["system-roles"],
    queryFn: async () => {
      const { data, error } = await supabase.from("roles").select("code, name_ru, name_kk").is("tenant_id", null);
      if (error) throw error;
      return data as { code: string; name_ru: string; name_kk: string }[];
    },
  });

  if (orgs.isLoading) return <LoadingScreen />;
  if (orgs.error) return <ErrorState error={orgs.error} onRetry={() => orgs.refetch()} />;
  const list = orgs.data ?? [];
  if (list.length === 0) return <Navigate to="/onboarding" replace />;
  if (list.length === 1) return <Navigate to={`/app/${list[0].slug}`} replace />;

  const roleName = (code: string) => {
    const r = roles.data?.find((x) => x.code === code);
    return r ? (i18n.language === "kk" ? r.name_kk : r.name_ru) : code;
  };

  return (
    <AuthLayout title={t("selectOrg.title")} subtitle={t("selectOrg.subtitle")}>
      <ul className="grid gap-2">
        {list.map((o) => (
          <li key={o.tenant_id}>
            <Link to={`/app/${o.slug}`} className="flex items-center gap-3 rounded-md border px-3 py-2.5 hover:bg-muted">
              <Building2 className="h-5 w-5 text-primary" />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-sm font-medium">{o.name}</span>
                <span className="block text-xs text-muted-foreground">{roleName(o.role_code)}</span>
              </span>
              <ChevronRight className="h-4 w-4 text-muted-foreground" />
            </Link>
          </li>
        ))}
      </ul>
      <Link to="/onboarding" className="mt-4 flex items-center justify-center gap-1 text-sm text-primary hover:underline">
        <Plus className="h-4 w-4" /> {t("selectOrg.createNew")}
      </Link>
    </AuthLayout>
  );
}
