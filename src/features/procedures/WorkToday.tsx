import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { ClipboardCheck, HeartPulse } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { todayInTimeZone, zonedDateTime } from "@/lib/format";
import { addDays } from "@/lib/bookings";
import { useAuth } from "@/auth/AuthProvider";
import { useOrg } from "@/auth/OrgProvider";
import { Card, CardContent } from "@/components/ui/card";

/** На главной: процедуры на сегодня и мои незакрытые задачи (реальные счётчики из БД) */
export function WorkToday() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const { org, can, hasFeature } = useOrg();
  const today = todayInTimeZone(org.timezone);
  const showProcedures = can("procedures.read") && hasFeature("procedures");
  const showTasks = can("tasks.read") && hasFeature("tasks");

  const procedures = useQuery({
    queryKey: ["appointments", org.id, "today-count", today],
    enabled: showProcedures,
    queryFn: async () => {
      const { count, error } = await supabase.from("procedure_appointments").select("id", { count: "exact", head: true })
        .eq("tenant_id", org.id).eq("status", "scheduled")
        .gte("starts_at", zonedDateTime(today, "00:00", org.timezone))
        .lt("starts_at", zonedDateTime(addDays(today, 1), "00:00", org.timezone));
      if (error) throw error;
      return count ?? 0;
    },
  });

  const tasks = useQuery({
    queryKey: ["tasks", org.id, "my-count", user?.id],
    enabled: showTasks && Boolean(user),
    queryFn: async () => {
      const { count, error } = await supabase.from("tasks").select("id", { count: "exact", head: true })
        .eq("tenant_id", org.id).in("status", ["open", "in_progress"])
        .or(`assignee_id.eq.${user!.id},assignee_id.is.null`);
      if (error) throw error;
      return count ?? 0;
    },
  });

  const tiles = [
    showProcedures && { key: "procedures", value: procedures.data, icon: HeartPulse, to: `/app/${org.slug}/procedures` },
    showTasks && { key: "tasks", value: tasks.data, icon: ClipboardCheck, to: `/app/${org.slug}/tasks` },
  ].filter(Boolean) as { key: string; value: number | undefined; icon: typeof HeartPulse; to: string }[];
  if (tiles.length === 0) return null;

  return (
    <div className="mt-3 grid grid-cols-2 gap-3 lg:grid-cols-4">
      {tiles.map((tile) => (
        <Link key={tile.key} to={tile.to} className="rounded-lg focus:outline-none focus-visible:ring-2 focus-visible:ring-ring">
          <Card className="h-full transition-colors hover:bg-muted/40">
            <CardContent className="pt-5">
              <div className="flex items-start justify-between gap-2 text-sm text-muted-foreground">
                {t(`dashboard.work.${tile.key}`)}
                <tile.icon className="mt-0.5 h-4 w-4 shrink-0" />
              </div>
              <p className="mt-2 text-2xl font-semibold tabular-nums">{tile.value ?? "…"}</p>
            </CardContent>
          </Card>
        </Link>
      ))}
    </div>
  );
}
