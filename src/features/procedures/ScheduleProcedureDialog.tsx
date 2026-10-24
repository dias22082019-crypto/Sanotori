import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { dateInTimeZone, formatKzPhone, formatKzt, formatTime, zonedDateTime, type AppLanguage } from "@/lib/format";
import {
  describeProcedureError, useProcedureTypes, useStaff, useTreatmentRooms, type Appointment,
} from "@/lib/procedures";
import { useOrg } from "@/auth/OrgProvider";
import { useGuestSearch } from "@/pages/app/GuestsPage";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect, Textarea } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";

export function invalidateProcedures(qc: ReturnType<typeof useQueryClient>, tenantId: string) {
  for (const key of ["appointments", "booking-appointments", "booking-balance", "bookings", "finance"]) {
    void qc.invalidateQueries({ queryKey: [key, tenantId] });
  }
}

/**
 * Запись гостя на процедуру или перенос записи. Цену, длительность, пересечения и даты проживания
 * проверяет сервер (schedule_procedure / reschedule_procedure); здесь цена только показывается.
 */
export function ScheduleProcedureDialog({ guest, bookingId, defaultTypeId, defaultDate, appointment, onClose }: {
  guest?: { id: string; full_name: string };
  bookingId?: string;
  /** Процедура, выбранная заранее (запись по назначению врача) */
  defaultTypeId?: string;
  defaultDate: string;
  appointment?: Appointment;
  onClose: () => void;
}) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const tz = org.timezone;

  const types = useProcedureTypes(org.id);
  const rooms = useTreatmentRooms(org.id);
  const staff = useStaff(org.id, "procedures.status");

  const [picked, setPicked] = useState(guest ?? null);
  const [search, setSearch] = useState("");
  const found = useGuestSearch(org.id, search, !picked && search.trim().length >= 2);

  const [typeId, setTypeId] = useState(appointment?.procedure_type_id ?? defaultTypeId ?? "");
  const [date, setDate] = useState(appointment ? dateInTimeZone(appointment.starts_at, tz) : defaultDate);
  const [time, setTime] = useState(appointment ? formatTime(appointment.starts_at, "ru", tz) : "10:00");
  const [roomId, setRoomId] = useState(appointment?.treatment_room_id ?? "");
  const [specialistId, setSpecialistId] = useState(appointment?.specialist_id ?? "");
  const [included, setIncluded] = useState(false);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);

  const activeTypes = types.data?.filter((x) => x.is_active || x.id === typeId) ?? [];
  const type = types.data?.find((x) => x.id === typeId);
  const activeRooms = rooms.data?.filter((r) => r.is_active || r.id === roomId) ?? [];

  const submit = async () => {
    if (!picked || !typeId || !date || !/^\d{2}:\d{2}/.test(time)) return toast.error(t("procedures.errors.fill"));
    setBusy(true);
    const startsAt = zonedDateTime(date, time, tz);
    const { error } = appointment
      ? await supabase.rpc("reschedule_procedure", {
          p_appointment_id: appointment.id, p_starts_at: startsAt, p_room_id: roomId || null, p_specialist_id: specialistId || null,
        })
      : await supabase.rpc("schedule_procedure", {
          p_guest_id: picked.id, p_procedure_type_id: typeId, p_starts_at: startsAt, p_booking_id: bookingId ?? null,
          p_room_id: roomId || null, p_specialist_id: specialistId || null, p_included: included, p_note: note || null,
        });
    setBusy(false);
    if (error) return toast.error(describeProcedureError(error, t));
    toast.success(t(appointment ? "procedures.moved" : "procedures.scheduled"));
    invalidateProcedures(qc, org.id);
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t(appointment ? "procedures.moveTitle" : "procedures.scheduleTitle")}>
      <div className="grid gap-4">
        <FormField id="pr-guest" label={t("procedures.fields.guest")}>
          {picked ? (
            <div className="flex items-center justify-between gap-2 rounded-md border px-3 py-2 text-sm">
              <span className="font-medium">{picked.full_name}</span>
              {!guest && !appointment && (
                <Button size="sm" variant="ghost" className="h-7" onClick={() => { setPicked(null); setSearch(""); }}>{t("procedures.changeGuest")}</Button>
              )}
            </div>
          ) : (
            <>
              <Input id="pr-guest" placeholder={t("procedures.guestSearch")} value={search} onChange={(e) => setSearch(e.target.value)} autoFocus />
              {search.trim().length >= 2 && (
                <ul className="max-h-48 divide-y overflow-y-auto rounded-md border text-sm">
                  {found.data?.length === 0 && <li className="px-3 py-2 text-muted-foreground">{t("procedures.noGuests")}</li>}
                  {found.data?.map((g) => (
                    <li key={g.id}>
                      <button type="button" className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left hover:bg-muted"
                        onClick={() => setPicked({ id: g.id, full_name: g.full_name })}>
                        <span>{g.full_name}</span>
                        {g.phone && <span className="text-xs text-muted-foreground">{formatKzPhone(g.phone)}</span>}
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </>
          )}
        </FormField>

        <FormField id="pr-type" label={t("procedures.fields.procedure")}
          hint={type ? `${t("procedures.minutes", { count: type.duration_min })} · ${formatKzt(type.price, lang)}` : undefined}>
          <NativeSelect id="pr-type" value={typeId} disabled={Boolean(appointment)} onChange={(e) => setTypeId(e.target.value)}>
            <option value="">—</option>
            {activeTypes.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
          </NativeSelect>
        </FormField>

        <div className="grid grid-cols-2 gap-3">
          <FormField id="pr-date" label={t("procedures.fields.date")}>
            <Input id="pr-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </FormField>
          <FormField id="pr-time" label={t("procedures.fields.time")}>
            <Input id="pr-time" type="time" step={300} value={time} onChange={(e) => setTime(e.target.value)} />
          </FormField>
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          <FormField id="pr-room" label={t("procedures.fields.room")}>
            <NativeSelect id="pr-room" value={roomId} onChange={(e) => setRoomId(e.target.value)}>
              <option value="">{t("procedures.notSet")}</option>
              {activeRooms.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="pr-spec" label={t("procedures.fields.specialist")}>
            <NativeSelect id="pr-spec" value={specialistId} onChange={(e) => setSpecialistId(e.target.value)}>
              <option value="">{t("procedures.notSet")}</option>
              {staff.data?.map((s) => <option key={s.user_id} value={s.user_id}>{s.full_name}</option>)}
            </NativeSelect>
          </FormField>
        </div>

        {!appointment && (
          <>
            <div className="flex items-center gap-2">
              <Checkbox id="pr-included" checked={included} onCheckedChange={(v) => setIncluded(v === true)} />
              <Label htmlFor="pr-included" className="font-normal">{t("procedures.fields.included")}</Label>
            </div>
            <FormField id="pr-note" label={t("procedures.fields.note")} hint={t("procedures.noteHint")}>
              <Textarea id="pr-note" rows={2} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} />
            </FormField>
            <p className="text-xs text-muted-foreground">{t("procedures.billingHint")}</p>
          </>
        )}
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy} onClick={submit}>{busy ? t("common.saving") : t("common.save")}</Button>
      </DialogFooter>
    </Dialog>
  );
}
