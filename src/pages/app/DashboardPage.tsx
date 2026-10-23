import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { BedDouble, CheckCircle2, Circle, Globe, Settings, Users } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/auth/AuthProvider";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";

/**
 * Обзор. Показатели (загрузка, заезды, доход) подключаются на этапе 3 вместе с номерами и бронированиями:
 * до этого страница не показывает чисел, которых нет в базе.
 */
export function DashboardPage() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const { org, can } = useOrg();
  const base = `/app/${org.slug}`;

  const staffCount = useQuery({
    queryKey: ["staff-count", org.id],
    enabled: can("members.read"),
    queryFn: async () => {
      const { count, error } = await supabase
        .from("organization_members")
        .select("id", { count: "exact", head: true })
        .eq("tenant_id", org.id);
      if (error) throw error;
      return count ?? 0;
    },
  });

  const name = (user?.user_metadata?.full_name as string | undefined) || user?.email || "";
  const steps = [
    { key: "stepProfile", done: Boolean(org.phone && org.address), to: `${base}/settings`, icon: Settings, show: can("settings.manage") },
    { key: "stepStaff", done: (staffCount.data ?? 0) > 1, to: `${base}/staff`, icon: Users, show: can("members.manage") },
    { key: "stepPublish", done: org.is_published, to: `${base}/settings`, icon: Globe, show: can("settings.manage") },
    { key: "stepRooms", done: false, to: undefined, icon: BedDouble, show: can("rooms.read") },
  ].filter((s) => s.show);

  return (
    <>
      <PageHeader title={t("dashboard.title")} description={t("dashboard.welcome", { name })} />
      {steps.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.setupTitle")}</CardTitle>
            <CardDescription>{t("dashboard.setupText")}</CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="divide-y">
              {steps.map((s) => (
                <li key={s.key} className="flex items-center gap-3 py-3">
                  {s.done ? <CheckCircle2 className="h-5 w-5 text-success" /> : <Circle className="h-5 w-5 text-muted-foreground" />}
                  <s.icon className="h-4 w-4 text-muted-foreground" />
                  <span className="flex-1 text-sm">{t(`dashboard.${s.key}`)}</span>
                  {s.done ? (
                    <span className="text-xs text-success">{t("dashboard.done")}</span>
                  ) : s.to ? (
                    <Button asChild size="sm" variant="outline"><Link to={s.to}>{t("dashboard.go")}</Link></Button>
                  ) : null}
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}
    </>
  );
}
