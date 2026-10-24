import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { Plus } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { todayInTimeZone } from "@/lib/format";
import type { Booking } from "@/lib/bookings";
import { APPOINTMENT_SELECT, useProcedureTypes, useStaff, useTreatmentRooms, type Appointment } from "@/lib/procedures";
import { useOrg } from "@/auth/OrgProvider";
import { Button } from "@/components/ui/button";
import { AppointmentList } from "./AppointmentList";
import { ScheduleProcedureDialog } from "./ScheduleProcedureDialog";

/** Процедуры гостя по брони. Стоимость попадает в остаток к оплате на сервере (booking_balances). */
export function BookingProcedures({ booking }: { booking: Booking }) {
  const { t } = useTranslation();
  const { org, can, writable, hasFeature } = useOrg();
  const [dialog, setDialog] = useState<"new" | Appointment | null>(null);
  const readsSchedule = can("procedures.read");

  const items = useQuery({
    queryKey: ["booking-appointments", org.id, booking.id],
    queryFn: async () => {
      const { data, error } = await supabase.from("procedure_appointments").select(APPOINTMENT_SELECT)
        .eq("booking_id", booking.id).order("starts_at");
      if (error) throw error;
      return data as unknown as Appointment[];
    },
  });
  const types = useProcedureTypes(org.id);
  const rooms = useTreatmentRooms(org.id, readsSchedule);
  const staff = useStaff(org.id, "procedures.status");

  const canSchedule = writable && hasFeature("procedures") && can("procedures.write")
    && ["confirmed", "checked_in"].includes(booking.status);
  const today = todayInTimeZone(org.timezone);
  const defaultDate = booking.check_in > today ? booking.check_in : today;
  const list = items.data ?? [];
  if (list.length === 0 && !canSchedule) return null;

  return (
    <section className="mt-5 border-t pt-4">
      <div className="flex items-center justify-between gap-2">
        <h3 className="text-sm font-semibold">{t("procedures.bookingTitle")}</h3>
        {canSchedule && (
          <Button size="sm" variant="outline" onClick={() => setDialog("new")}><Plus /> {t("procedures.schedule")}</Button>
        )}
      </div>
      {list.length === 0 ? (
        <p className="mt-2 text-sm text-muted-foreground">{t("procedures.noneForBooking")}</p>
      ) : (
        <AppointmentList items={list} types={types.data ?? []} rooms={rooms.data ?? []} staff={staff.data ?? []}
          showGuest={false} showDate onMove={(a) => setDialog(a)} />
      )}
      {dialog && (
        <ScheduleProcedureDialog
          guest={booking.guest ? { id: booking.guest_id, full_name: booking.guest.full_name } : undefined}
          bookingId={booking.id} defaultDate={defaultDate}
          appointment={dialog === "new" ? undefined : dialog} onClose={() => setDialog(null)} />
      )}
    </section>
  );
}
