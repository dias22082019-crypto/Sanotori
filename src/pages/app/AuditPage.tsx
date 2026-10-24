import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { Download, ScrollText } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { formatDateTime, todayInTimeZone, zonedDateTime, type AppLanguage } from "@/lib/format";
import { addDays } from "@/lib/bookings";
import { downloadCsv } from "@/lib/finance";
import { AUDIT_GROUPS, auditActionLabel, auditDetailsText, auditGroupFilter, type AuditEntry, type AuditGroup } from "@/lib/audit";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";

const PAGE = 100;

/** Журнал действий санатория (audit.read). Записи только читаются: изменить или удалить их нельзя даже владельцу. */
export function AuditPage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const tz = org.timezone;
  const today = todayInTimeZone(tz);
  const [from, setFrom] = useState(addDays(today, -6));
  const [to, setTo] = useState(today);
  const [actor, setActor] = useState("");
  const [group, setGroup] = useState<AuditGroup | "">("");

  // имена сотрудников: участники санатория и их профили (RLS отдаёт коллег)
  const people = useQuery({
    queryKey: ["audit-people", org.id],
    queryFn: async () => {
      const { data: members, error } = await supabase.from("organization_members").select("user_id").eq("tenant_id", org.id);
      if (error) throw error;
      const ids = (members ?? []).map((m) => m.user_id as string);
      if (ids.length === 0) return new Map<string, string>();
      const { data: profiles, error: e2 } = await supabase.from("user_profiles").select("id, full_name").in("id", ids);
      if (e2) throw e2;
      return new Map((profiles ?? []).map((p) => [p.id as string, (p.full_name as string | null) || "—"]));
    },
  });

  const log = useInfiniteQuery({
    queryKey: ["audit", org.id, from, to, actor, group],
    initialPageParam: null as number | null,
    queryFn: async ({ pageParam }) => {
      let q = supabase.from("audit_logs").select("id, actor_user_id, action, entity_type, entity_id, result, details, created_at")
        .eq("tenant_id", org.id)
        .gte("created_at", zonedDateTime(from, "00:00", tz))
        .lt("created_at", zonedDateTime(addDays(to, 1), "00:00", tz))
        .order("id", { ascending: false }).limit(PAGE);
      if (pageParam !== null) q = q.lt("id", pageParam);
      if (actor) q = q.eq("actor_user_id", actor);
      if (group) q = q.or(auditGroupFilter(group));
      const { data, error } = await q;
      if (error) throw error;
      return data as AuditEntry[];
    },
    getNextPageParam: (last) => (last.length === PAGE ? last[last.length - 1].id : undefined),
  });

  const rows = log.data?.pages.flat() ?? [];
  const who = (id: string | null) => (id ? people.data?.get(id) ?? t("audit.platform") : t("audit.system"));

  const exportCsv = () => downloadCsv(`audit_${from}_${to}.csv`, [
    [t("audit.csv.time"), t("audit.csv.actor"), t("audit.csv.action"), t("audit.csv.code"), t("audit.csv.details")],
    ...rows.map((r) => [formatDateTime(r.created_at, lang, tz), who(r.actor_user_id), auditActionLabel(r.action, t), r.action,
      auditDetailsText(r.details, lang, t, tz)]),
  ]);

  return (
    <>
      <PageHeader title={t("audit.title")} description={t("audit.subtitle")}
        actions={<Button variant="outline" disabled={rows.length === 0} onClick={exportCsv}><Download /> CSV</Button>} />

      <Card>
        <CardHeader className="pb-2">
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <FormField id="audit-from" label={t("audit.from")}>
              <Input id="audit-from" type="date" value={from} max={to} onChange={(e) => e.target.value && setFrom(e.target.value)} />
            </FormField>
            <FormField id="audit-to" label={t("audit.to")}>
              <Input id="audit-to" type="date" value={to} min={from} onChange={(e) => e.target.value && setTo(e.target.value)} />
            </FormField>
            <FormField id="audit-actor" label={t("audit.actor")}>
              <NativeSelect id="audit-actor" value={actor} onChange={(e) => setActor(e.target.value)}>
                <option value="">{t("audit.everyone")}</option>
                {[...(people.data ?? new Map<string, string>())].sort((a, b) => a[1].localeCompare(b[1]))
                  .map(([id, name]) => <option key={id} value={id}>{name}</option>)}
              </NativeSelect>
            </FormField>
            <FormField id="audit-group" label={t("audit.group")}>
              <NativeSelect id="audit-group" value={group} onChange={(e) => setGroup(e.target.value as AuditGroup | "")}>
                <option value="">{t("audit.allGroups")}</option>
                {(Object.keys(AUDIT_GROUPS) as AuditGroup[]).map((g) => <option key={g} value={g}>{t(`audit.groups.${g}`)}</option>)}
              </NativeSelect>
            </FormField>
          </div>
        </CardHeader>
        <CardContent>
          {log.isLoading ? (
            <div className="grid gap-2">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-10" />)}</div>
          ) : log.error ? (
            <ErrorState error={log.error} onRetry={() => log.refetch()} />
          ) : rows.length === 0 ? (
            <EmptyState icon={<ScrollText className="h-5 w-5" />} title={t("audit.empty")} />
          ) : (
            <>
              <ul className="divide-y">
                {rows.map((r) => {
                  const details = auditDetailsText(r.details, lang, t, tz);
                  return (
                    <li key={r.id} className="grid gap-x-4 gap-y-0.5 py-2.5 text-sm sm:grid-cols-[150px_180px_1fr]">
                      <span className="tabular-nums text-muted-foreground">{formatDateTime(r.created_at, lang, tz)}</span>
                      <span className="truncate">{who(r.actor_user_id)}</span>
                      <span className="min-w-0">
                        <span className="font-medium">{auditActionLabel(r.action, t)}</span>
                        {r.result !== "success" && <Badge variant="destructive" className="ml-2">{t(`audit.result.${r.result}`)}</Badge>}
                        {details && <span className="block break-words text-xs text-muted-foreground">{details}</span>}
                      </span>
                    </li>
                  );
                })}
              </ul>
              {log.hasNextPage && (
                <div className="mt-3 flex justify-center">
                  <Button variant="outline" disabled={log.isFetchingNextPage} onClick={() => log.fetchNextPage()}>
                    {log.isFetchingNextPage ? t("common.loading") : t("audit.more")}
                  </Button>
                </div>
              )}
            </>
          )}
          <p className="mt-4 text-xs text-muted-foreground">{t("audit.note")}</p>
        </CardContent>
      </Card>
    </>
  );
}
