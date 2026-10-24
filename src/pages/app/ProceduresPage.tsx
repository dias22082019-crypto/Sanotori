import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ChevronLeft, ChevronRight, HeartPulse, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { formatKzt, todayInTimeZone, zonedDateTime, type AppLanguage } from "@/lib/format";
import { addDays } from "@/lib/bookings";
import {
  APPOINTMENT_SELECT, describeProcedureError, useProcedureTypes, useStaff, useTreatmentRooms,
  type Appointment, type ProcedureType,
} from "@/lib/procedures";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
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
import { AppointmentList } from "@/features/procedures/AppointmentList";
import { ScheduleProcedureDialog } from "@/features/procedures/ScheduleProcedureDialog";

const TABS = ["schedule", "catalog"] as const;
type Tab = (typeof TABS)[number];

/** Процедуры: расписание на день и справочник процедур и кабинетов */
export function ProceduresPage() {
  const { t } = useTranslation();
  const { org, can, writable, hasFeature } = useOrg();
  const [params, setParams] = useSearchParams();
  const tab: Tab = params.get("tab") === "catalog" ? "catalog" : "schedule";
  const today = todayInTimeZone(org.timezone);
  const date = /^\d{4}-\d{2}-\d{2}$/.test(params.get("date") ?? "") ? params.get("date")! : today;
  const [specialist, setSpecialist] = useState("");
  const [dialog, setDialog] = useState<"new" | Appointment | null>(null);

  const enabled = hasFeature("procedures");
  const canWrite = writable && enabled && can("procedures.write");
  const types = useProcedureTypes(org.id);
  const rooms = useTreatmentRooms(org.id);
  const staff = useStaff(org.id, "procedures.status");

  const day = useQuery({
    queryKey: ["appointments", org.id, date],
    queryFn: async () => {
      const { data, error } = await supabase.from("procedure_appointments").select(APPOINTMENT_SELECT)
        .eq("tenant_id", org.id)
        .gte("starts_at", zonedDateTime(date, "00:00", org.timezone))
        .lt("starts_at", zonedDateTime(addDays(date, 1), "00:00", org.timezone))
        .order("starts_at").limit(500);
      if (error) throw error;
      return data as unknown as Appointment[];
    },
  });

  const setDate = (d: string) => setParams({ tab, date: d }, { replace: true });
  const items = (day.data ?? []).filter((a) => !specialist || a.specialist_id === specialist);
  const live = items.filter((a) => a.status !== "cancelled");
  const done = live.filter((a) => a.status === "done").length;

  return (
    <>
      <PageHeader
        title={t("procedures.title")}
        description={t("procedures.subtitle")}
        actions={canWrite && tab === "schedule" && (types.data?.length ?? 0) > 0 && (
          <Button onClick={() => setDialog("new")}><Plus /> {t("procedures.schedule")}</Button>
        )}
      />

      {!enabled && (
        <Card className="mb-4 border-warning/40 bg-warning/5">
          <CardContent className="py-3 text-sm">{t("procedures.planNote")}</CardContent>
        </Card>
      )}

      <div className="-mx-4 mb-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
        <div role="tablist" className="inline-flex gap-1 rounded-lg bg-muted p-1">
          {TABS.map((key) => (
            <button key={key} role="tab" aria-selected={tab === key}
              className={cn("whitespace-nowrap rounded-md px-3 py-1.5 text-sm", tab === key ? "bg-card font-medium shadow-sm" : "text-muted-foreground hover:text-foreground")}
              onClick={() => setParams({ tab: key, date }, { replace: true })}>
              {t(`procedures.tabs.${key}`)}
            </button>
          ))}
        </div>
      </div>

      {tab === "catalog" ? <Catalog canWrite={canWrite} /> : (
        <Card>
          <CardHeader className="flex-row flex-wrap items-center gap-2 space-y-0">
            <div className="flex items-center gap-1">
              <Button size="icon" variant="outline" className="h-9 w-9" aria-label={t("procedures.prevDay")} onClick={() => setDate(addDays(date, -1))}><ChevronLeft /></Button>
              <Input type="date" className="w-40" value={date} aria-label={t("procedures.fields.date")} onChange={(e) => e.target.value && setDate(e.target.value)} />
              <Button size="icon" variant="outline" className="h-9 w-9" aria-label={t("procedures.nextDay")} onClick={() => setDate(addDays(date, 1))}><ChevronRight /></Button>
              {date !== today && <Button size="sm" variant="ghost" onClick={() => setDate(today)}>{t("procedures.today")}</Button>}
            </div>
            <NativeSelect className="w-full sm:ml-auto sm:w-56" value={specialist} aria-label={t("procedures.fields.specialist")}
              onChange={(e) => setSpecialist(e.target.value)}>
              <option value="">{t("procedures.allSpecialists")}</option>
              {staff.data?.map((s) => <option key={s.user_id} value={s.user_id}>{s.full_name}</option>)}
            </NativeSelect>
          </CardHeader>
          <CardContent>
            {day.isLoading || types.isLoading ? (
              <div className="grid gap-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-12" />)}</div>
            ) : day.error ? (
              <ErrorState error={day.error} onRetry={() => day.refetch()} />
            ) : items.length === 0 ? (
              <EmptyState icon={<HeartPulse className="h-5 w-5" />} title={t("procedures.emptyDay")}
                text={(types.data?.length ?? 0) === 0 ? t("procedures.needCatalog") : undefined} />
            ) : (
              <>
                <p className="mb-1 text-xs text-muted-foreground">{t("procedures.daySummary", { count: live.length, done })}</p>
                <AppointmentList items={items} types={types.data ?? []} rooms={rooms.data ?? []} staff={staff.data ?? []}
                  onMove={(a) => setDialog(a)} />
              </>
            )}
          </CardContent>
        </Card>
      )}

      {dialog && (
        <ScheduleProcedureDialog defaultDate={date < today ? today : date}
          appointment={dialog === "new" ? undefined : dialog} onClose={() => setDialog(null)} />
      )}
    </>
  );
}

/** Справочник: процедуры с длительностью и ценой, кабинеты */
function Catalog({ canWrite }: { canWrite: boolean }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const types = useProcedureTypes(org.id);
  const rooms = useTreatmentRooms(org.id);
  const [editing, setEditing] = useState<ProcedureType | "new" | null>(null);
  const [roomName, setRoomName] = useState("");

  const addRoom = async () => {
    if (!roomName.trim()) return;
    const { error } = await supabase.from("treatment_rooms").insert({ tenant_id: org.id, name: roomName.trim() });
    if (error) return toast.error(describeProcedureError(error, t));
    setRoomName("");
    void qc.invalidateQueries({ queryKey: ["treatment-rooms", org.id] });
  };
  const toggleRoom = async (id: string, isActive: boolean) => {
    const { error } = await supabase.from("treatment_rooms").update({ is_active: isActive }).eq("id", id);
    if (error) return toast.error(describeProcedureError(error, t));
    void qc.invalidateQueries({ queryKey: ["treatment-rooms", org.id] });
  };

  return (
    <div className="grid gap-4 lg:grid-cols-[1fr_340px]">
      <Card className="min-w-0">
        <CardHeader className="flex-row items-start justify-between gap-2 space-y-0">
          <div>
            <CardTitle>{t("procedures.catalogTitle")}</CardTitle>
            <CardDescription>{t("procedures.catalogText")}</CardDescription>
          </div>
          {canWrite && <Button size="sm" onClick={() => setEditing("new")}><Plus /> {t("procedures.addType")}</Button>}
        </CardHeader>
        <CardContent>
          {types.isLoading ? <Skeleton className="h-24" /> : types.error ? <ErrorState error={types.error} onRetry={() => types.refetch()} /> :
            types.data!.length === 0 ? <p className="text-sm text-muted-foreground">{t("procedures.noTypes")}</p> : (
              <ul className="divide-y">
                {types.data!.map((x) => (
                  <li key={x.id} className={cn("flex items-center gap-3 py-2.5", !x.is_active && "text-muted-foreground")}>
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium">{x.name} {!x.is_active && <Badge variant="secondary" className="ml-1">{t("procedures.inactive")}</Badge>}</p>
                      {x.description && <p className="truncate text-xs text-muted-foreground">{x.description}</p>}
                    </div>
                    <span className="whitespace-nowrap text-xs text-muted-foreground">{t("procedures.minutes", { count: x.duration_min })}</span>
                    <span className="w-24 whitespace-nowrap text-right text-sm tabular-nums">{formatKzt(x.price, lang)}</span>
                    {canWrite && (
                      <Button size="icon" variant="ghost" className="h-8 w-8" aria-label={t("common.edit")} onClick={() => setEditing(x)}><Pencil /></Button>
                    )}
                  </li>
                ))}
              </ul>
            )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("procedures.roomsTitle")}</CardTitle>
          <CardDescription>{t("procedures.roomsText")}</CardDescription>
        </CardHeader>
        <CardContent>
          {rooms.isLoading ? <Skeleton className="h-16" /> : (rooms.data?.length ?? 0) === 0 ? (
            <p className="text-sm text-muted-foreground">{t("procedures.noRooms")}</p>
          ) : (
            <ul className="divide-y">
              {rooms.data!.map((r) => (
                <li key={r.id} className={cn("flex items-center gap-2 py-2 text-sm", !r.is_active && "text-muted-foreground")}>
                  <span className="flex-1">{r.name}</span>
                  {canWrite ? (
                    <Button size="sm" variant="ghost" className="h-7 text-xs" onClick={() => toggleRoom(r.id, !r.is_active)}>
                      {r.is_active ? t("procedures.deactivate") : t("procedures.activate")}
                    </Button>
                  ) : !r.is_active && <Badge variant="secondary">{t("procedures.inactive")}</Badge>}
                </li>
              ))}
            </ul>
          )}
          {canWrite && (
            <div className="mt-3 flex gap-2">
              <Input placeholder={t("procedures.roomPlaceholder")} aria-label={t("procedures.fields.room")} value={roomName} maxLength={100}
                onChange={(e) => setRoomName(e.target.value)} onKeyDown={(e) => e.key === "Enter" && addRoom()} />
              <Button variant="outline" disabled={!roomName.trim()} onClick={addRoom}><Plus /> {t("procedures.addRoom")}</Button>
            </div>
          )}
        </CardContent>
      </Card>

      {editing && <ProcedureTypeDialog value={editing === "new" ? null : editing} onClose={() => setEditing(null)} />}
    </div>
  );
}

function ProcedureTypeDialog({ value, onClose }: { value: ProcedureType | null; onClose: () => void }) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [name, setName] = useState(value?.name ?? "");
  const [duration, setDuration] = useState(String(value?.duration_min ?? 30));
  const [price, setPrice] = useState(value ? String(Number(value.price)) : "");
  const [description, setDescription] = useState(value?.description ?? "");
  const [isActive, setIsActive] = useState(value?.is_active ?? true);
  const [busy, setBusy] = useState(false);

  const save = async () => {
    const minutes = Number(duration);
    const amount = Number(price.replace(/\s/g, "").replace(",", ".") || 0);
    if (!name.trim() || !Number.isInteger(minutes) || minutes < 5 || minutes > 480 || !Number.isFinite(amount) || amount < 0) {
      return toast.error(t("procedures.errors.typeForm"));
    }
    const row = { name: name.trim(), duration_min: minutes, price: amount, description: description.trim() || null, is_active: isActive };
    setBusy(true);
    const { error } = value
      ? await supabase.from("procedure_types").update(row).eq("id", value.id)
      : await supabase.from("procedure_types").insert({ ...row, tenant_id: org.id });
    setBusy(false);
    if (error) return toast.error(describeProcedureError(error, t));
    toast.success(t("common.saved"));
    void qc.invalidateQueries({ queryKey: ["procedure-types", org.id] });
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={value ? t("procedures.editType") : t("procedures.addType")}>
      <div className="grid gap-4">
        <FormField id="pt-name" label={t("procedures.fields.name")}>
          <Input id="pt-name" value={name} maxLength={200} placeholder={t("procedures.namePlaceholder")} onChange={(e) => setName(e.target.value)} autoFocus />
        </FormField>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="pt-duration" label={t("procedures.fields.duration")}>
            <Input id="pt-duration" inputMode="numeric" value={duration} onChange={(e) => setDuration(e.target.value)} />
          </FormField>
          <FormField id="pt-price" label={t("procedures.fields.price")} hint={value ? t("procedures.priceHint") : undefined}>
            <Input id="pt-price" inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} />
          </FormField>
        </div>
        <FormField id="pt-desc" label={t("procedures.fields.description")}>
          <Textarea id="pt-desc" rows={2} maxLength={1000} value={description} onChange={(e) => setDescription(e.target.value)} />
        </FormField>
        <div className="flex items-center gap-2">
          <Checkbox id="pt-active" checked={isActive} onCheckedChange={(v) => setIsActive(v === true)} />
          <Label htmlFor="pt-active" className="font-normal">{t("procedures.fields.active")}</Label>
        </div>
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy} onClick={save}>{busy ? t("common.saving") : t("common.save")}</Button>
      </DialogFooter>
    </Dialog>
  );
}
