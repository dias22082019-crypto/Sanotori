import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, ArrowLeft, CalendarPlus, ClipboardPlus, FileText, Lock, Pencil, Plus, Search, Stethoscope } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { formatDate, formatDateTime, formatKzPhone, todayInTimeZone, zonedDateTime, dateInTimeZone, formatTime, type AppLanguage } from "@/lib/format";
import {
  RECORD_FIELDS, VISIT_KINDS, ageOn, describeMedicalError, isBloodPressure, overviewNeeds, parseMeasure, prescriptionStatusVariant,
  type MedicalCard, type MedicalOverviewRow, type MedicalVisit, type MedicalVisitKind, type Prescription, type PrescriptionStatus,
} from "@/lib/medical";
import { useProcedureTypes } from "@/lib/procedures";
import { useOrg } from "@/auth/OrgProvider";
import { useGuestSearch } from "@/pages/app/GuestsPage";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect, Textarea } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";
import { ScheduleProcedureDialog } from "@/features/procedures/ScheduleProcedureDialog";
import { StayDietCard } from "@/pages/app/KitchenPage";

/** Медкарты: гости в санатории и сегодняшние заезды, поиск гостя */
export function MedicalPage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, hasFeature } = useOrg();
  const [search, setSearch] = useState("");

  const overview = useQuery({
    queryKey: ["medical-overview", org.id],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("medical_overview", { p_tenant: org.id });
      if (error) throw error;
      return data as MedicalOverviewRow[];
    },
  });
  const found = useGuestSearch(org.id, search, search.trim().length >= 2);
  const inHouse = overview.data?.filter((r) => r.status === "checked_in") ?? [];
  const arriving = overview.data?.filter((r) => r.status !== "checked_in") ?? [];

  return (
    <>
      <PageHeader title={t("medical.title")} description={t("medical.subtitle")} />
      {!hasFeature("procedures") && (
        <Card className="mb-4 border-warning/40 bg-warning/5">
          <CardContent className="py-3 text-sm">{t("medical.planNote")}</CardContent>
        </Card>
      )}

      <div className="relative mb-4 max-w-md">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input className="pl-9" value={search} onChange={(e) => setSearch(e.target.value)} placeholder={t("medical.searchPlaceholder")} aria-label={t("medical.searchPlaceholder")} />
      </div>

      {search.trim().length >= 2 ? (
        <Card>
          <CardContent className="p-0">
            {found.isLoading ? <Skeleton className="m-4 h-10" /> : found.error ? <ErrorState error={found.error} onRetry={() => found.refetch()} /> :
              found.data!.length === 0 ? <p className="p-4 text-sm text-muted-foreground">{t("medical.notFound")}</p> : (
                <ul className="divide-y">
                  {found.data!.map((g) => (
                    <li key={g.id}>
                      <Link to={g.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-4 py-3 text-sm hover:bg-muted/50">
                        <span className="font-medium">{g.full_name}</span>
                        {g.birth_date && <span className="text-muted-foreground">{formatDate(g.birth_date, lang)}</span>}
                        {g.phone && <span className="text-muted-foreground">{formatKzPhone(g.phone)}</span>}
                      </Link>
                    </li>
                  ))}
                </ul>
              )}
          </CardContent>
        </Card>
      ) : overview.isLoading ? <Skeleton className="h-40" /> : overview.error ? (
        <ErrorState error={overview.error} onRetry={() => overview.refetch()} />
      ) : overview.data!.length === 0 ? (
        <EmptyState icon={<Stethoscope />} title={t("medical.emptyTitle")} text={t("medical.emptyText")} />
      ) : (
        <div className="space-y-6">
          {[{ key: "inHouse", rows: inHouse }, { key: "arriving", rows: arriving }].filter((s) => s.rows.length > 0).map((s) => (
            <section key={s.key}>
              <h2 className="mb-2 text-sm font-semibold text-muted-foreground">{t(`medical.${s.key}`)} · {s.rows.length}</h2>
              <Card>
                <ul className="divide-y">
                  {s.rows.map((r) => <OverviewRow key={r.booking_id} row={r} lang={lang} />)}
                </ul>
              </Card>
            </section>
          ))}
        </div>
      )}
    </>
  );
}

function OverviewRow({ row, lang }: { row: MedicalOverviewRow; lang: AppLanguage }) {
  const { t } = useTranslation();
  const need = overviewNeeds(row);
  return (
    <li>
      <Link to={row.guest_id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-4 py-3 text-sm hover:bg-muted/50">
        <span className="min-w-0 font-medium">{row.full_name}</span>
        <span className="text-muted-foreground">
          {row.room_number ? `${t("medical.room")} ${row.room_number} · ` : ""}{formatDate(row.check_in, lang)} — {formatDate(row.check_out, lang)}
        </span>
        <span className="ml-auto flex flex-wrap gap-1.5">
          {need && <Badge variant="warning" className="whitespace-nowrap">{t(`medical.needs.${need}`)}</Badge>}
          {row.active_prescriptions > 0 && (
            <Badge variant="secondary" className="whitespace-nowrap">{t("medical.activeRx", { count: row.active_prescriptions })}</Badge>
          )}
        </span>
      </Link>
    </li>
  );
}

/** Медкарта гостя. Каждое открытие сервер записывает в журнал, поэтому карта не перезапрашивается сама. */
export function MedicalCardPage() {
  const { guestId = "" } = useParams();
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can } = useOrg();
  const [dialog, setDialog] = useState<"record" | "visit" | "rx" | MedicalVisit | null>(null);
  const [scheduling, setScheduling] = useState<Prescription | null>(null);

  const card = useQuery({
    queryKey: ["medical-card", guestId],
    staleTime: Infinity,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_medical_card", { p_guest_id: guestId });
      if (error) throw error;
      return data as MedicalCard;
    },
  });

  const back = (
    <Button asChild variant="ghost" size="sm" className="-ml-2 mb-2">
      <Link to=".." relative="path"><ArrowLeft /> {t("medical.backToList")}</Link>
    </Button>
  );
  if (card.isLoading) return <>{back}<Skeleton className="h-64" /></>;
  if (card.error) return <>{back}<ErrorState error={card.error} onRetry={() => card.refetch()} /></>;

  const c = card.data!;
  const today = todayInTimeZone(org.timezone);
  const age = ageOn(c.guest.birth_date, today);
  const canWrite = c.can_write;
  const record = c.record;

  return (
    <>
      {back}
      <PageHeader
        title={c.guest.full_name}
        description={[
          age !== null ? t("medical.age", { count: age }) : null,
          c.guest.city,
          c.stay ? `${t("medical.stay", { number: c.stay.number })}: ${formatDate(c.stay.check_in, lang)} — ${formatDate(c.stay.check_out, lang)}` : null,
        ].filter(Boolean).join(" · ") || undefined}
        actions={record && (
          <>
            <Button asChild variant="outline"><Link to={`/app/${org.slug}/print/medical/${c.guest.id}`}><FileText /> {t("medical.extract")}</Link></Button>
            {canWrite && <Button variant="outline" onClick={() => setDialog("rx")}><ClipboardPlus /> {t("medical.addRx")}</Button>}
            {canWrite && <Button onClick={() => setDialog("visit")}><Plus /> {t("medical.addVisit")}</Button>}
          </>
        )}
      />

      <p className="mb-4 flex items-center gap-2 text-xs text-muted-foreground">
        <Lock className="h-3.5 w-3.5 shrink-0" /> {t("medical.loggedNote")}
      </p>

      <div className="grid gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
        <div className="min-w-0 space-y-4">
          <Card>
            <CardHeader className="flex-row items-center justify-between gap-2 space-y-0">
              <CardTitle className="text-base">{t("medical.record")}</CardTitle>
              {canWrite && record && (
                <Button variant="ghost" size="sm" onClick={() => setDialog("record")}><Pencil /> {t("common.edit")}</Button>
              )}
            </CardHeader>
            <CardContent>
              {!record ? (
                <div className="space-y-3 text-sm">
                  <p className="text-muted-foreground">{t("medical.noRecord")}</p>
                  {canWrite && <Button onClick={() => setDialog("record")}><Plus /> {t("medical.createRecord")}</Button>}
                </div>
              ) : (
                <dl className="space-y-3 text-sm">
                  {RECORD_FIELDS.map((f) => {
                    const value = record[f];
                    const alert = (f === "allergies" || f === "contraindications") && value;
                    return (
                      <div key={f} className={alert ? "rounded-md border border-destructive/30 bg-destructive/5 p-2" : undefined}>
                        <dt className="flex items-center gap-1.5 text-xs font-medium text-muted-foreground">
                          {alert && <AlertTriangle className="h-3.5 w-3.5 text-destructive" />}{t(`medical.fields.${f}`)}
                        </dt>
                        <dd className="mt-0.5 whitespace-pre-line break-words">{value ?? <span className="text-muted-foreground">—</span>}</dd>
                      </div>
                    );
                  })}
                  <p className="border-t pt-2 text-xs text-muted-foreground">
                    {t("medical.consentAt", { date: formatDateTime(record.consent_at, lang, org.timezone) })}
                    {record.updated_by_name ? ` · ${t("medical.updatedBy", { name: record.updated_by_name, date: formatDateTime(record.updated_at, lang, org.timezone) })}` : ""}
                  </p>
                </dl>
              )}
            </CardContent>
          </Card>

          {c.stay && <StayDietCard bookingId={c.stay.id} guestName={c.guest.full_name} />}

          <Card>
            <CardHeader><CardTitle className="text-base">{t("medical.prescriptions")}</CardTitle></CardHeader>
            <CardContent>
              {c.prescriptions.length === 0 ? <p className="text-sm text-muted-foreground">{t("medical.noRx")}</p> : (
                <ul className="space-y-3">
                  {c.prescriptions.map((p) => (
                    <PrescriptionItem key={p.id} rx={p} lang={lang} canWrite={canWrite}
                      canSchedule={can("procedures.write") && canWrite && p.status === "active"}
                      onSchedule={() => setScheduling(p)} />
                  ))}
                </ul>
              )}
            </CardContent>
          </Card>
        </div>

        <Card className="min-w-0">
          <CardHeader><CardTitle className="text-base">{t("medical.visits")}</CardTitle></CardHeader>
          <CardContent>
            {c.visits.length === 0 ? <p className="text-sm text-muted-foreground">{t("medical.noVisits")}</p> : (
              <ol className="space-y-4">
                {c.visits.map((v) => <VisitItem key={v.id} visit={v} lang={lang} onEdit={canWrite && v.editable ? () => setDialog(v) : undefined} />)}
              </ol>
            )}
          </CardContent>
        </Card>
      </div>

      {dialog === "record" && <RecordDialog guestId={c.guest.id} record={record} onClose={() => setDialog(null)} />}
      {dialog === "rx" && <PrescriptionDialog guestId={c.guest.id} bookingId={c.stay?.id ?? null} onClose={() => setDialog(null)} />}
      {(dialog === "visit" || (dialog && typeof dialog === "object")) && (
        <VisitDialog guestId={c.guest.id} bookingId={c.stay?.id ?? null} hasInitial={c.visits.some((v) => v.kind === "initial")}
          visit={typeof dialog === "object" ? dialog : undefined} onClose={() => setDialog(null)} />
      )}
      {scheduling && (
        <ScheduleProcedureDialog guest={{ id: c.guest.id, full_name: c.guest.full_name }} bookingId={c.stay?.id}
          defaultTypeId={scheduling.procedure_type_id} defaultDate={today}
          onClose={() => { setScheduling(null); void card.refetch(); }} />
      )}
    </>
  );
}

function useRefreshCard(guestId: string) {
  const qc = useQueryClient();
  const { org } = useOrg();
  return () => {
    void qc.invalidateQueries({ queryKey: ["medical-card", guestId] });
    void qc.invalidateQueries({ queryKey: ["medical-overview", org.id] });
  };
}

function VisitItem({ visit: v, lang, onEdit }: { visit: MedicalVisit; lang: AppLanguage; onEdit?: () => void }) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const vitals = [
    v.blood_pressure && `${t("medical.fields.blood_pressure")} ${v.blood_pressure}`,
    v.pulse !== null && `${t("medical.fields.pulse")} ${v.pulse}`,
    v.temperature !== null && `${t("medical.fields.temperature")} ${v.temperature} °C`,
    v.weight !== null && `${t("medical.fields.weight")} ${v.weight} ${t("medical.kg")}`,
  ].filter(Boolean);
  return (
    <li className="rounded-md border p-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={v.kind === "initial" ? "default" : "secondary"} className="whitespace-nowrap">{t(`medical.kind.${v.kind}`)}</Badge>
        <span className="text-muted-foreground">{formatDateTime(v.visit_at, lang, org.timezone)}{v.doctor_name ? ` · ${v.doctor_name}` : ""}</span>
        {onEdit && <Button variant="ghost" size="sm" className="ml-auto h-7" onClick={onEdit}><Pencil /> {t("common.edit")}</Button>}
      </div>
      {vitals.length > 0 && <p className="mt-2 text-xs text-muted-foreground">{vitals.join(" · ")}</p>}
      <dl className="mt-2 space-y-2">
        {(["complaints", "examination", "diagnosis", "recommendations"] as const).filter((f) => v[f]).map((f) => (
          <div key={f}>
            <dt className="text-xs font-medium text-muted-foreground">{t(`medical.fields.${f}`)}</dt>
            <dd className={f === "diagnosis" ? "whitespace-pre-line break-words font-medium" : "whitespace-pre-line break-words"}>{v[f]}</dd>
          </div>
        ))}
      </dl>
    </li>
  );
}

function PrescriptionItem({ rx, lang, canWrite, canSchedule, onSchedule }: {
  rx: Prescription; lang: AppLanguage; canWrite: boolean; canSchedule: boolean; onSchedule: () => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const pct = Math.min(100, Math.round((rx.done / rx.sessions) * 100));

  const setStatus = async (status: PrescriptionStatus) => {
    setBusy(true);
    const { error } = await supabase.rpc("set_prescription_status", { p_prescription_id: rx.id, p_status: status });
    setBusy(false);
    if (error) return toast.error(describeMedicalError(error, t));
    void qc.invalidateQueries({ queryKey: ["medical-card"] });
    void qc.invalidateQueries({ queryKey: ["medical-overview"] });
  };

  return (
    <li className="rounded-md border p-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <span className="min-w-0 font-medium">{rx.procedure}</span>
        <Badge variant={prescriptionStatusVariant[rx.status]} className="whitespace-nowrap">{t(`medical.rxStatus.${rx.status}`)}</Badge>
      </div>
      <div className="mt-2 flex items-center gap-2">
        <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-muted" role="progressbar" aria-valuemin={0} aria-valuemax={rx.sessions} aria-valuenow={rx.done}>
          <div className="h-full rounded-full bg-primary" style={{ width: `${pct}%` }} />
        </div>
        <span className="whitespace-nowrap text-xs text-muted-foreground">{t("medical.progress", { done: rx.done, total: rx.sessions })}</span>
      </div>
      {(rx.frequency || rx.note) && (
        <p className="mt-2 whitespace-pre-line break-words text-muted-foreground">{[rx.frequency, rx.note].filter(Boolean).join(" · ")}</p>
      )}
      <p className="mt-1 text-xs text-muted-foreground">
        {formatDate(rx.created_at.slice(0, 10), lang)}{rx.prescribed_by_name ? ` · ${rx.prescribed_by_name}` : ""}
      </p>
      {(canSchedule || canWrite) && (
        <div className="mt-2 flex flex-wrap gap-2">
          {canSchedule && <Button size="sm" variant="outline" onClick={onSchedule}><CalendarPlus /> {t("medical.scheduleRx")}</Button>}
          {canWrite && rx.status === "active" && (
            <>
              <Button size="sm" variant="ghost" disabled={busy} onClick={() => setStatus("completed")}>{t("medical.rxComplete")}</Button>
              <Button size="sm" variant="ghost" disabled={busy} onClick={() => setStatus("cancelled")}>{t("medical.rxCancel")}</Button>
            </>
          )}
          {canWrite && rx.status !== "active" && (
            <Button size="sm" variant="ghost" disabled={busy} onClick={() => setStatus("active")}>{t("medical.rxResume")}</Button>
          )}
        </div>
      )}
    </li>
  );
}

function RecordDialog({ guestId, record, onClose }: { guestId: string; record: MedicalCard["record"]; onClose: () => void }) {
  const { t } = useTranslation();
  const refresh = useRefreshCard(guestId);
  const [values, setValues] = useState(() => Object.fromEntries(RECORD_FIELDS.map((f) => [f, record?.[f] ?? ""])) as Record<(typeof RECORD_FIELDS)[number], string>);
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!record && !consent) return toast.error(t("medical.errors.consent"));
    setBusy(true);
    const { error } = await supabase.rpc("save_medical_record", {
      p_guest_id: guestId, p_allergies: values.allergies, p_contraindications: values.contraindications,
      p_chronic_conditions: values.chronic_conditions, p_medications: values.medications, p_notes: values.notes, p_consent: consent,
    });
    setBusy(false);
    if (error) return toast.error(describeMedicalError(error, t));
    toast.success(t("common.saved"));
    refresh();
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t(record ? "medical.editRecord" : "medical.createRecord")} className="sm:max-w-xl">
      <form onSubmit={submit} className="space-y-3">
        {RECORD_FIELDS.map((f) => (
          <FormField key={f} id={`rec-${f}`} label={t(`medical.fields.${f}`)} hint={f === "allergies" ? t("medical.allergiesHint") : undefined}>
            <Textarea id={`rec-${f}`} rows={f === "notes" ? 3 : 2} maxLength={f === "notes" ? 4000 : 2000} value={values[f]}
              onChange={(e) => setValues({ ...values, [f]: e.target.value })} />
          </FormField>
        ))}
        {!record && (
          <div className="flex items-start gap-2 rounded-md bg-muted p-3">
            <Checkbox id="rec-consent" checked={consent} onCheckedChange={(v) => setConsent(v === true)} className="mt-0.5" />
            <Label htmlFor="rec-consent" className="text-sm font-normal leading-snug">{t("medical.consentLabel")}</Label>
          </div>
        )}
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={busy || (!record && !consent)}>{busy ? t("common.saving") : t("common.save")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}

function VisitDialog({ guestId, bookingId, hasInitial, visit, onClose }: {
  guestId: string; bookingId: string | null; hasInitial: boolean; visit?: MedicalVisit; onClose: () => void;
}) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const refresh = useRefreshCard(guestId);
  const tz = org.timezone;
  const nowIso = new Date().toISOString();
  const [kind, setKind] = useState<MedicalVisitKind>(visit?.kind ?? (hasInitial ? "follow_up" : "initial"));
  const [date, setDate] = useState(dateInTimeZone(visit?.visit_at ?? nowIso, tz));
  const [time, setTime] = useState(formatTime(visit?.visit_at ?? nowIso, "ru", tz));
  const [text, setText] = useState({
    complaints: visit?.complaints ?? "", examination: visit?.examination ?? "",
    diagnosis: visit?.diagnosis ?? "", recommendations: visit?.recommendations ?? "",
  });
  const [bp, setBp] = useState(visit?.blood_pressure ?? "");
  const [pulse, setPulse] = useState(visit?.pulse?.toString() ?? "");
  const [temp, setTemp] = useState(visit?.temperature?.toString() ?? "");
  const [weight, setWeight] = useState(visit?.weight?.toString() ?? "");
  const [busy, setBusy] = useState(false);

  const nums = { pulse: parseMeasure(pulse), temperature: parseMeasure(temp), weight: parseMeasure(weight) };
  const bpError = !isBloodPressure(bp);
  const numError = Object.values(nums).some((n) => Number.isNaN(n));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (bpError || numError) return toast.error(t("medical.errors.vitals"));
    if (!/^\d{2}:\d{2}/.test(time) || !date) return toast.error(t("medical.errors.visitTime"));
    setBusy(true);
    const common = {
      p_kind: kind, p_visit_at: zonedDateTime(date, time.slice(0, 5), tz),
      p_complaints: text.complaints, p_examination: text.examination, p_diagnosis: text.diagnosis, p_recommendations: text.recommendations,
      p_blood_pressure: bp.trim() || null, p_pulse: nums.pulse, p_temperature: nums.temperature, p_weight: nums.weight,
    };
    const { error } = visit
      ? await supabase.rpc("update_medical_visit", { p_visit_id: visit.id, ...common })
      : await supabase.rpc("add_medical_visit", { p_guest_id: guestId, p_booking_id: bookingId, ...common });
    setBusy(false);
    if (error) return toast.error(describeMedicalError(error, t));
    toast.success(t("common.saved"));
    refresh();
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t(visit ? "medical.editVisit" : "medical.addVisit")}
      description={visit ? t("medical.editWindow") : undefined} className="sm:max-w-2xl">
      <form onSubmit={submit} className="space-y-3">
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          <FormField id="visit-kind" label={t("medical.kindLabel")}>
            <NativeSelect id="visit-kind" value={kind} onChange={(e) => setKind(e.target.value as MedicalVisitKind)}>
              {VISIT_KINDS.map((k) => <option key={k} value={k}>{t(`medical.kind.${k}`)}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="visit-date" label={t("medical.date")}>
            <Input id="visit-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </FormField>
          <FormField id="visit-time" label={t("medical.time")}>
            <Input id="visit-time" type="time" value={time} onChange={(e) => setTime(e.target.value)} />
          </FormField>
        </div>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <FormField id="visit-bp" label={t("medical.fields.blood_pressure")} error={bpError ? t("medical.bpHint") : undefined}>
            <Input id="visit-bp" inputMode="numeric" placeholder="120/80" value={bp} onChange={(e) => setBp(e.target.value)} />
          </FormField>
          <FormField id="visit-pulse" label={t("medical.fields.pulse")}>
            <Input id="visit-pulse" inputMode="numeric" value={pulse} onChange={(e) => setPulse(e.target.value)} />
          </FormField>
          <FormField id="visit-temp" label={`${t("medical.fields.temperature")}, °C`}>
            <Input id="visit-temp" inputMode="decimal" value={temp} onChange={(e) => setTemp(e.target.value)} />
          </FormField>
          <FormField id="visit-weight" label={`${t("medical.fields.weight")}, ${t("medical.kg")}`}>
            <Input id="visit-weight" inputMode="decimal" value={weight} onChange={(e) => setWeight(e.target.value)} />
          </FormField>
        </div>
        {(["complaints", "examination", "diagnosis", "recommendations"] as const).map((f) => (
          <FormField key={f} id={`visit-${f}`} label={t(`medical.fields.${f}`)}>
            <Textarea id={`visit-${f}`} rows={f === "diagnosis" ? 2 : 3} maxLength={f === "diagnosis" ? 2000 : 4000} value={text[f]}
              onChange={(e) => setText({ ...text, [f]: e.target.value })} />
          </FormField>
        ))}
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={busy}>{busy ? t("common.saving") : t("common.save")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}

function PrescriptionDialog({ guestId, bookingId, onClose }: { guestId: string; bookingId: string | null; onClose: () => void }) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const refresh = useRefreshCard(guestId);
  const types = useProcedureTypes(org.id);
  const [typeId, setTypeId] = useState("");
  const [sessions, setSessions] = useState("10");
  const [frequency, setFrequency] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const active = types.data?.filter((x) => x.is_active) ?? [];

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const n = Number(sessions);
    if (!typeId) return toast.error(t("medical.errors.procedure"));
    if (!Number.isInteger(n) || n < 1 || n > 60) return toast.error(t("medical.errors.sessions"));
    setBusy(true);
    const { error } = await supabase.rpc("add_prescription", {
      p_guest_id: guestId, p_booking_id: bookingId, p_procedure_type_id: typeId, p_sessions: n,
      p_frequency: frequency || null, p_note: note || null,
    });
    setBusy(false);
    if (error) return toast.error(describeMedicalError(error, t));
    toast.success(t("medical.rxAdded"));
    refresh();
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("medical.addRx")}>
      <form onSubmit={submit} className="space-y-3">
        <FormField id="rx-type" label={t("medical.procedure")}
          hint={types.data && active.length === 0 ? t("medical.noProcedureTypes") : undefined}>
          <NativeSelect id="rx-type" value={typeId} onChange={(e) => setTypeId(e.target.value)}>
            <option value="">{t("medical.chooseProcedure")}</option>
            {active.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
          </NativeSelect>
        </FormField>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="rx-sessions" label={t("medical.sessions")}>
            <Input id="rx-sessions" type="number" min={1} max={60} value={sessions} onChange={(e) => setSessions(e.target.value)} />
          </FormField>
          <FormField id="rx-frequency" label={t("medical.frequency")}>
            <Input id="rx-frequency" maxLength={100} placeholder={t("medical.frequencyPlaceholder")} value={frequency} onChange={(e) => setFrequency(e.target.value)} />
          </FormField>
        </div>
        <FormField id="rx-note" label={t("medical.rxNote")}>
          <Textarea id="rx-note" rows={2} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} />
        </FormField>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={busy}>{busy ? t("common.saving") : t("common.save")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
