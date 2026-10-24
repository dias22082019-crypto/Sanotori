import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { BedDouble, Inbox, LogIn, LogOut } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useOrg } from "@/auth/OrgProvider";
import { Card, CardContent } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorState } from "@/components/states/ErrorState";

interface Summary {
  arrivals: number;
  departures: number;
  in_house: number;
  requests: number;
  rooms_total: number;
  rooms_occupied: number;
}

/** Показатели на сегодня: считаются сервером по броням, в часовом поясе санатория */
export function TodaySummary() {
  const { t } = useTranslation();
  const { org } = useOrg();
  const base = `/app/${org.slug}/bookings`;
  const q = useQuery({
    queryKey: ["today-summary", org.id],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("today_summary", { p_tenant: org.id });
      if (error) throw error;
      return data as Summary;
    },
  });

  if (q.isLoading) return <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-24" />)}</div>;
  if (q.error || !q.data) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  const s = q.data;
  const occupancy = s.rooms_total > 0 ? Math.round((s.rooms_occupied / s.rooms_total) * 100) : null;
  const tiles = [
    { key: "arrivals", value: s.arrivals, icon: LogIn, to: `${base}?tab=arrivals` },
    { key: "departures", value: s.departures, icon: LogOut, to: `${base}?tab=in_house` },
    { key: "occupancy", value: occupancy === null ? "—" : `${occupancy}%`, icon: BedDouble, to: `/app/${org.slug}/calendar`,
      note: t("dashboard.occupancyNote", { occupied: s.rooms_occupied, total: s.rooms_total }) },
    { key: "requests", value: s.requests, icon: Inbox, to: `${base}?tab=requests` },
  ];

  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      {tiles.map((tile) => (
        <Link key={tile.key} to={tile.to} className="rounded-lg focus:outline-none focus-visible:ring-2 focus-visible:ring-ring">
          <Card className="h-full transition-colors hover:bg-muted/40">
            <CardContent className="pt-5">
              <div className="flex items-start justify-between gap-2 text-sm text-muted-foreground">
                {t(`dashboard.today.${tile.key}`)}
                <tile.icon className="mt-0.5 h-4 w-4 shrink-0" />
              </div>
              <p className="mt-2 text-2xl font-semibold tabular-nums">{tile.value}</p>
              {tile.note && <p className="mt-0.5 text-xs text-muted-foreground">{tile.note}</p>}
            </CardContent>
          </Card>
        </Link>
      ))}
    </div>
  );
}
