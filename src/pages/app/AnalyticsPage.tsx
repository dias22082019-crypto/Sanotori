import { useState } from "react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { BarChart3, Download } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Legend, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { supabase } from "@/lib/supabase";
import { formatDate, formatKzt, todayInTimeZone, type AppLanguage } from "@/lib/format";
import { downloadCsv } from "@/lib/finance";
import {
  ANALYTICS_PRESETS, kpis, occupancySeries, percent, presetRange,
  type AnalyticsPreset, type AnalyticsReport,
} from "@/lib/analytics";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";

// Цвета серий проверены на различимость, в том числе при нарушениях цветового зрения
const SERIES_1 = "#0f9a8a";
const SERIES_2 = "#eb6834";
const AXIS = { fontSize: 12, fill: "hsl(var(--muted-foreground))" };

const monthLabel = (iso: string, lang: AppLanguage) =>
  new Intl.DateTimeFormat(lang === "kk" ? "kk-KZ" : "ru-RU", { month: "short", year: "2-digit", timeZone: "UTC" })
    .format(new Date(`${iso}T00:00:00Z`));
const num = (v: number, lang: AppLanguage) => v.toLocaleString(lang === "kk" ? "kk-KZ" : "ru-RU", { maximumFractionDigits: 1 });
const dayLabel = (iso: string) => `${iso.slice(8, 10)}.${iso.slice(5, 7)}`;
const compactKzt = (v: number, lang: AppLanguage) =>
  new Intl.NumberFormat(lang === "kk" ? "kk-KZ" : "ru-RU", { notation: "compact", maximumFractionDigits: 1 }).format(v);

/** Аналитика санатория (reports.read, модуль analytics): загрузка, деньги, источники, категории, процедуры */
export function AnalyticsPage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, hasFeature } = useOrg();
  const today = todayInTimeZone(org.timezone);
  const [preset, setPreset] = useState<AnalyticsPreset>("thisMonth");
  const [custom, setCustom] = useState(presetRange("thisMonth", today));
  const { from, to } = preset === "custom" ? custom : presetRange(preset, today);
  const enabled = hasFeature("analytics");

  const report = useQuery({
    queryKey: ["analytics", org.id, from, to],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("analytics_report", { p_tenant: org.id, p_from: from, p_to: to });
      if (error) throw error;
      return data as AnalyticsReport;
    },
  });

  if (!enabled) {
    return (
      <>
        <PageHeader title={t("analytics.title")} description={t("analytics.subtitle")} />
        <EmptyState icon={<BarChart3 className="h-5 w-5" />} title={t("analytics.notInPlan")} text={t("analytics.notInPlanText")}
          action={can("billing.manage") ? <Button asChild><Link to={`/app/${org.slug}/billing`}>{t("subscription.manage")}</Link></Button> : undefined} />
      </>
    );
  }

  const r = report.data;
  const k = r ? kpis(r) : null;
  const tooLong = preset === "custom" && (Date.parse(to) - Date.parse(from)) / 86_400_000 > 366;

  const exportCsv = () => {
    if (!r || !k) return;
    const money = (v: number | string) => Number(v);
    downloadCsv(`analytics_${from}_${to}.csv`, [
      [t("analytics.title"), `${from} — ${to}`],
      [t("analytics.kpi.occupancy"), `${k.occupancy}%`],
      [t("analytics.kpi.adr"), k.adr],
      [t("analytics.kpi.revpar"), k.revpar],
      [t("analytics.kpi.roomNights"), r.room_nights],
      [t("analytics.kpi.accommodation"), money(r.accommodation)],
      [t("analytics.kpi.received"), money(r.received)],
      [t("analytics.kpi.expenses"), money(r.expenses)],
      [t("analytics.kpi.bookings"), r.bookings.created],
      [t("analytics.kpi.cancelRate"), `${k.cancelRate}%`],
      [t("analytics.kpi.avgNights"), Number(r.bookings.avg_nights)],
      [t("analytics.kpi.leadDays"), Number(r.bookings.avg_lead_days)],
      [t("analytics.kpi.guests"), r.guests],
      [t("analytics.kpi.returning"), r.returning_guests],
      [],
      [t("analytics.csv.month"), t("analytics.kpi.occupancy"), t("analytics.kpi.roomNights"), t("analytics.kpi.accommodation"), t("analytics.kpi.received"), t("analytics.kpi.expenses")],
      ...r.monthly.map((m) => [m.month.slice(0, 7), `${percent(m.room_nights, r.rooms * m.days)}%`, m.room_nights, money(m.accommodation), money(m.received), money(m.expenses)]),
      [],
      [t("analytics.csv.source"), t("analytics.csv.bookings"), t("analytics.csv.cancelled"), t("analytics.csv.amount")],
      ...r.sources.map((s) => [t(`bookings.source.${s.source}`), s.bookings, s.cancelled, money(s.amount)]),
      [],
      [t("analytics.csv.roomType"), t("analytics.csv.rooms"), t("analytics.kpi.roomNights"), t("analytics.kpi.occupancy"), t("analytics.kpi.accommodation")],
      ...r.room_types.map((x) => [x.name, x.rooms, x.room_nights, `${percent(x.room_nights, x.rooms * r.days)}%`, money(x.accommodation)]),
      [],
      [t("analytics.csv.procedure"), t("analytics.csv.done"), t("analytics.csv.noShow"), t("analytics.csv.amount")],
      ...r.procedures.map((p) => [p.name, p.done, p.no_show, money(p.amount)]),
    ]);
  };

  const occupancy = r ? occupancySeries(r) : [];
  const byMonth = occupancy[0]?.byMonth ?? false;
  const moneyData = r?.monthly.map((m) => ({ month: m.month, received: Number(m.received), expenses: Number(m.expenses) })) ?? [];
  const maxSource = Math.max(1, ...(r?.sources.map((s) => s.bookings) ?? []));

  return (
    <>
      <PageHeader title={t("analytics.title")} description={t("analytics.subtitle")}
        actions={<Button variant="outline" disabled={!r} onClick={exportCsv}><Download /> CSV</Button>} />

      <div className="mb-4 grid gap-3 sm:grid-cols-[220px_auto] sm:items-end">
        <FormField id="an-preset" label={t("analytics.period")}>
          <NativeSelect id="an-preset" value={preset} onChange={(e) => {
            const v = e.target.value as AnalyticsPreset;
            if (v === "custom") setCustom({ from, to });
            setPreset(v);
          }}>
            {ANALYTICS_PRESETS.map((p) => <option key={p} value={p}>{t(`analytics.presets.${p}`)}</option>)}
          </NativeSelect>
        </FormField>
        {preset === "custom" ? (
          <div className="grid grid-cols-2 gap-3 sm:w-80">
            <FormField id="an-from" label={t("audit.from")}>
              <Input id="an-from" type="date" value={custom.from} max={custom.to} onChange={(e) => e.target.value && setCustom({ ...custom, from: e.target.value })} />
            </FormField>
            <FormField id="an-to" label={t("audit.to")}>
              <Input id="an-to" type="date" value={custom.to} min={custom.from} onChange={(e) => e.target.value && setCustom({ ...custom, to: e.target.value })} />
            </FormField>
          </div>
        ) : (
          <p className="pb-2 text-sm text-muted-foreground">{formatDate(from, lang)} — {formatDate(to, lang)}</p>
        )}
      </div>

      {tooLong ? <p className="text-sm text-destructive">{t("analytics.tooLong")}</p> : report.error ? (
        <ErrorState error={report.error} onRetry={() => report.refetch()} />
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {[
              { key: "occupancy", value: k && `${num(k.occupancy, lang)}%`, note: r && t("analytics.kpi.occupancyNote", { nights: r.room_nights, rooms: r.rooms }) },
              { key: "adr", value: k && formatKzt(k.adr, lang), note: t("analytics.kpi.adrNote") },
              { key: "revpar", value: k && formatKzt(k.revpar, lang), note: t("analytics.kpi.revparNote") },
              { key: "received", value: r && formatKzt(r.received, lang), note: r && t("analytics.kpi.accrued", { amount: formatKzt(r.accommodation, lang) }) },
              { key: "bookings", value: r && String(r.bookings.created), note: k && t("analytics.kpi.cancelNote", { value: num(k.cancelRate, lang) }) },
              { key: "avgNights", value: r && num(Number(r.bookings.avg_nights), lang), note: r && t("analytics.kpi.leadNote", { value: num(Number(r.bookings.avg_lead_days), lang) }) },
              { key: "guests", value: r && String(r.guests), note: r && t("analytics.kpi.returningNote", { count: r.returning_guests }) },
              { key: "expenses", value: r && formatKzt(r.expenses, lang), note: t("analytics.kpi.expensesNote") },
            ].map((tile) => (
              <Card key={tile.key}>
                <CardContent className="pt-5">
                  <p className="text-sm text-muted-foreground">{t(`analytics.kpi.${tile.key}`)}</p>
                  {!tile.value ? <Skeleton className="mt-2 h-7 w-24" /> : <p className="mt-1.5 text-2xl font-semibold tabular-nums">{tile.value}</p>}
                  {tile.note && <p className="mt-0.5 text-xs text-muted-foreground">{tile.note}</p>}
                </CardContent>
              </Card>
            ))}
          </div>

          <div className="mt-4 grid gap-4 lg:grid-cols-2">
            <Card className="min-w-0">
              <CardHeader>
                <CardTitle>{t("analytics.occupancyTitle")}</CardTitle>
                <CardDescription>{t(byMonth ? "analytics.occupancyByMonth" : "analytics.occupancyByDay")}</CardDescription>
              </CardHeader>
              <CardContent>
                {!r ? <Skeleton className="h-64" /> : r.rooms === 0 ? <p className="text-sm text-muted-foreground">{t("analytics.noRooms")}</p> : (
                  <div className="h-64">
                    <ResponsiveContainer width="100%" height="100%">
                      <BarChart data={occupancy} margin={{ top: 8, right: 8, left: -12, bottom: 0 }} barCategoryGap={2}>
                        <CartesianGrid vertical={false} stroke="hsl(var(--border))" />
                        <XAxis dataKey="key" tick={AXIS} tickLine={false} axisLine={false} minTickGap={16}
                          tickFormatter={(v: string) => (byMonth ? monthLabel(v, lang) : dayLabel(v))} />
                        <YAxis tick={AXIS} tickLine={false} axisLine={false} domain={[0, 100]} ticks={[0, 25, 50, 75, 100]} tickFormatter={(v) => `${v}%`} />
                        <Tooltip cursor={{ fill: "hsl(var(--muted))" }}
                          labelFormatter={(v) => (byMonth ? monthLabel(String(v), lang) : formatDate(String(v), lang))}
                          formatter={(v) => [`${num(Number(v), lang)}%`, t("analytics.kpi.occupancy")]} />
                        <Bar dataKey="occupancy" fill={SERIES_1} radius={[4, 4, 0, 0]} maxBarSize={36} />
                      </BarChart>
                    </ResponsiveContainer>
                  </div>
                )}
              </CardContent>
            </Card>

            <Card className="min-w-0">
              <CardHeader>
                <CardTitle>{t("analytics.moneyTitle")}</CardTitle>
                <CardDescription>{t("analytics.moneyText")}</CardDescription>
              </CardHeader>
              <CardContent>
                {!r ? <Skeleton className="h-64" /> : (
                  <div className="h-64">
                    <ResponsiveContainer width="100%" height="100%">
                      <BarChart data={moneyData} margin={{ top: 8, right: 8, left: 0, bottom: 0 }} barGap={2}>
                        <CartesianGrid vertical={false} stroke="hsl(var(--border))" />
                        <XAxis dataKey="month" tick={AXIS} tickLine={false} axisLine={false} tickFormatter={(v: string) => monthLabel(v, lang)} />
                        <YAxis tick={AXIS} tickLine={false} axisLine={false} tickFormatter={(v: number) => compactKzt(v, lang)} width={56} />
                        <Tooltip cursor={{ fill: "hsl(var(--muted))" }} labelFormatter={(v) => monthLabel(String(v), lang)}
                          formatter={(v, name) => [formatKzt(Number(v), lang), t(`analytics.series.${name}`)]} />
                        <Legend formatter={(name) => <span className="text-sm text-foreground">{t(`analytics.series.${name}`)}</span>} iconType="square" />
                        <Bar dataKey="received" fill={SERIES_1} radius={[4, 4, 0, 0]} maxBarSize={36} />
                        <Bar dataKey="expenses" fill={SERIES_2} radius={[4, 4, 0, 0]} maxBarSize={36} />
                      </BarChart>
                    </ResponsiveContainer>
                  </div>
                )}
              </CardContent>
            </Card>
          </div>

          <div className="mt-4 grid gap-4 lg:grid-cols-2">
            <Card className="min-w-0">
              <CardHeader>
                <CardTitle>{t("analytics.sourcesTitle")}</CardTitle>
                <CardDescription>{t("analytics.sourcesText")}</CardDescription>
              </CardHeader>
              <CardContent>
                {!r ? <Skeleton className="h-32" /> : r.sources.length === 0 ? <p className="text-sm text-muted-foreground">{t("analytics.noBookings")}</p> : (
                  <ul className="grid gap-3 text-sm">
                    {r.sources.map((s) => (
                      <li key={s.source}>
                        <div className="flex items-baseline justify-between gap-3">
                          <span className="font-medium">{t(`bookings.source.${s.source}`)}</span>
                          <span className="tabular-nums text-muted-foreground">
                            {t("analytics.sourceLine", { count: s.bookings, amount: formatKzt(s.amount, lang) })}
                            {s.cancelled > 0 && ` · ${t("analytics.sourceCancelled", { count: s.cancelled })}`}
                          </span>
                        </div>
                        <div className="mt-1 h-2 rounded-full bg-muted">
                          <div className="h-2 rounded-full" style={{ width: `${(s.bookings / maxSource) * 100}%`, background: SERIES_1 }} />
                        </div>
                      </li>
                    ))}
                  </ul>
                )}
              </CardContent>
            </Card>

            <Card className="min-w-0">
              <CardHeader>
                <CardTitle>{t("analytics.roomTypesTitle")}</CardTitle>
                <CardDescription>{t("analytics.roomTypesText")}</CardDescription>
              </CardHeader>
              <CardContent>
                {!r ? <Skeleton className="h-32" /> : (
                  <div className="-mx-5 overflow-x-auto">
                    <table className="w-full min-w-[420px] text-sm">
                      <thead className="text-left text-xs text-muted-foreground">
                        <tr>
                          <th className="px-5 pb-2 font-normal">{t("analytics.csv.roomType")}</th>
                          <th className="px-2 pb-2 text-right font-normal">{t("analytics.csv.rooms")}</th>
                          <th className="px-2 pb-2 text-right font-normal">{t("analytics.kpi.roomNights")}</th>
                          <th className="px-2 pb-2 text-right font-normal">{t("analytics.kpi.occupancy")}</th>
                          <th className="px-5 pb-2 text-right font-normal">{t("analytics.kpi.accommodation")}</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y">
                        {r.room_types.map((x) => (
                          <tr key={x.name}>
                            <td className="px-5 py-2">{x.name}</td>
                            <td className="px-2 py-2 text-right tabular-nums">{x.rooms}</td>
                            <td className="px-2 py-2 text-right tabular-nums">{x.room_nights}</td>
                            <td className="px-2 py-2 text-right tabular-nums">{num(percent(x.room_nights, x.rooms * r.days), lang)}%</td>
                            <td className="whitespace-nowrap px-5 py-2 text-right tabular-nums">{formatKzt(x.accommodation, lang)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </CardContent>
            </Card>
          </div>

          {hasFeature("procedures") && (
            <Card className="mt-4 min-w-0">
              <CardHeader>
                <CardTitle>{t("analytics.proceduresTitle")}</CardTitle>
                <CardDescription>{t("analytics.proceduresText")}</CardDescription>
              </CardHeader>
              <CardContent>
                {!r ? <Skeleton className="h-24" /> : r.procedures.length === 0 ? <p className="text-sm text-muted-foreground">{t("analytics.noProcedures")}</p> : (
                  <div className="-mx-5 overflow-x-auto">
                    <table className="w-full min-w-[420px] text-sm">
                      <thead className="text-left text-xs text-muted-foreground">
                        <tr>
                          <th className="px-5 pb-2 font-normal">{t("analytics.csv.procedure")}</th>
                          <th className="px-2 pb-2 text-right font-normal">{t("analytics.csv.done")}</th>
                          <th className="px-2 pb-2 text-right font-normal">{t("analytics.csv.noShow")}</th>
                          <th className="px-5 pb-2 text-right font-normal">{t("analytics.csv.amount")}</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y">
                        {r.procedures.map((p) => (
                          <tr key={p.name}>
                            <td className="px-5 py-2">{p.name}</td>
                            <td className="px-2 py-2 text-right tabular-nums">{p.done}</td>
                            <td className="px-2 py-2 text-right tabular-nums">{p.no_show}</td>
                            <td className="whitespace-nowrap px-5 py-2 text-right tabular-nums">{formatKzt(p.amount, lang)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </CardContent>
            </Card>
          )}

          <p className="mt-4 text-xs text-muted-foreground">{t("analytics.method")}</p>
        </>
      )}
    </>
  );
}
