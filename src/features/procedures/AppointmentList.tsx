import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { dateInTimeZone, formatDate, formatKzt, formatTime, todayInTimeZone, type AppLanguage } from "@/lib/format";
import {
  describeProcedureError, procedureStatusVariant,
  type Appointment, type ProcedureStatus, type ProcedureType, type StaffMember, type TreatmentRoom,
} from "@/lib/procedures";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { invalidateProcedures } from "./ScheduleProcedureDialog";

/** Список записей на процедуры с действиями по правам. Переходы статусов проверяет set_procedure_status(). */
export function AppointmentList({ items, types, rooms, staff, showGuest = true, showDate = false, onMove }: {
  items: Appointment[];
  types: ProcedureType[];
  rooms: TreatmentRoom[];
  staff: StaffMember[];
  showGuest?: boolean;
  showDate?: boolean;
  onMove: (a: Appointment) => void;
}) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable, hasFeature } = useOrg();
  const qc = useQueryClient();
  const tz = org.timezone;
  const today = todayInTimeZone(tz);
  const active = writable && hasFeature("procedures");
  const canStatus = active && can("procedures.status");
  const canWrite = active && can("procedures.write");
  const [cancelling, setCancelling] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  const setStatus = async (a: Appointment, status: ProcedureStatus, why?: string) => {
    setBusy(true);
    const { error } = await supabase.rpc("set_procedure_status", { p_appointment_id: a.id, p_status: status, p_reason: why ?? null });
    setBusy(false);
    if (error) return toast.error(describeProcedureError(error, t));
    toast.success(t(`procedures.statusChanged.${status}`));
    setCancelling(null);
    invalidateProcedures(qc, org.id);
  };

  const typeName = (id: string) => types.find((x) => x.id === id)?.name ?? "—";
  const roomName = (id: string | null) => rooms.find((r) => r.id === id)?.name;
  const staffName = (id: string | null) => staff.find((s) => s.user_id === id)?.full_name;

  return (
    <ul className="divide-y">
      {items.map((a) => {
        const day = dateInTimeZone(a.starts_at, tz);
        const meta = [roomName(a.treatment_room_id), staffName(a.specialist_id)].filter(Boolean).join(" · ");
        const closed = a.status === "cancelled";
        return (
          <li key={a.id} className={cn("py-3", closed && "text-muted-foreground")}>
            <div className="flex flex-wrap items-start gap-x-3 gap-y-1">
              <div className="order-1 w-24 shrink-0 text-sm tabular-nums">
                {showDate && <span className="block text-xs text-muted-foreground">{formatDate(day, lang)}</span>}
                {formatTime(a.starts_at, lang, tz)}–{formatTime(a.ends_at, lang, tz)}
              </div>
              <div className="order-3 w-full min-w-0 sm:order-2 sm:w-auto sm:flex-1">
                <p className={cn("text-sm font-medium", closed && "line-through")}>
                  {typeName(a.procedure_type_id)}
                  {showGuest && <span className="font-normal"> · {a.guest?.full_name}</span>}
                </p>
                <p className="text-xs text-muted-foreground">
                  {meta || t("procedures.noRoomOrSpecialist")}
                  {a.note && ` · ${a.note}`}
                  {a.cancel_reason && ` · ${a.cancel_reason.startsWith("booking ") ? t("procedures.bookingCancelled") : a.cancel_reason}`}
                </p>
              </div>
              <div className="order-2 ml-auto flex shrink-0 items-center gap-2 sm:order-3">
                <span className="whitespace-nowrap text-xs text-muted-foreground">{a.included ? t("procedures.includedShort") : formatKzt(a.price, lang)}</span>
                <Badge variant={procedureStatusVariant[a.status]}>{t(`procedures.status.${a.status}`)}</Badge>
              </div>
            </div>

            {cancelling === a.id ? (
              <div className="mt-2 flex flex-wrap gap-2 sm:pl-[6.75rem]">
                <Input className="h-8 min-w-0 flex-1" placeholder={t("procedures.cancelReason")} value={reason} maxLength={500}
                  onChange={(e) => setReason(e.target.value)} autoFocus />
                <Button size="sm" variant="destructive" disabled={busy} onClick={() => setStatus(a, "cancelled", reason)}>{t("procedures.actions.cancel")}</Button>
                <Button size="sm" variant="ghost" onClick={() => setCancelling(null)}>{t("common.back")}</Button>
              </div>
            ) : (
              <div className="mt-1.5 flex flex-wrap gap-1.5 sm:pl-[6.75rem]">
                {a.status === "scheduled" && canStatus && day <= today && (
                  <>
                    <Button size="sm" className="h-7" disabled={busy} onClick={() => setStatus(a, "done")}>{t("procedures.actions.done")}</Button>
                    <Button size="sm" variant="outline" className="h-7" disabled={busy} onClick={() => setStatus(a, "no_show")}>{t("procedures.actions.noShow")}</Button>
                  </>
                )}
                {a.status === "scheduled" && canWrite && (
                  <>
                    <Button size="sm" variant="outline" className="h-7" onClick={() => onMove(a)}>{t("procedures.actions.move")}</Button>
                    <Button size="sm" variant="ghost" className="h-7 text-destructive" onClick={() => { setCancelling(a.id); setReason(""); }}>
                      {t("procedures.actions.cancel")}
                    </Button>
                  </>
                )}
                {(a.status === "done" || a.status === "no_show") && canWrite && (
                  <Button size="sm" variant="ghost" className="h-7" disabled={busy} onClick={() => setStatus(a, "scheduled")}>{t("procedures.actions.undo")}</Button>
                )}
              </div>
            )}
          </li>
        );
      })}
    </ul>
  );
}
