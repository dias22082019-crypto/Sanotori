import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { formatDate, formatDateTime, formatKzPhone, formatKzt, todayInTimeZone, whatsappLink, type AppLanguage } from "@/lib/format";
import { bookingStatusVariant, describeBookingError, type Booking, type BookingStatus, type Room, type RoomType } from "@/lib/bookings";
import { useOrg } from "@/auth/OrgProvider";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";
import { Dialog } from "@/components/ui/dialog";
import { BookingPayments } from "@/features/finance/BookingPayments";
import { BookingProcedures } from "@/features/procedures/BookingProcedures";
import { BookingMarketing } from "@/features/marketing/BookingMarketing";
import { invalidateBookings } from "./BookingDialog";

/** Карточка брони с действиями по статусу. Права и правила переходов проверяет set_booking_status() на сервере. */
export function BookingDetailsDialog({ booking, rooms, roomTypes, onEdit, onClose }: {
  booking: Booking;
  rooms: Room[];
  roomTypes: RoomType[];
  onEdit: () => void;
  onClose: () => void;
}) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable, hasFeature } = useOrg();
  const qc = useQueryClient();
  const today = todayInTimeZone(org.timezone);
  const [busy, setBusy] = useState(false);
  const [cancelMode, setCancelMode] = useState<"cancelled" | "no_show" | null>(null);
  const [reason, setReason] = useState("");
  const [confirmRoom, setConfirmRoom] = useState("");

  const b = booking;
  const room = rooms.find((r) => r.id === b.room_id);
  const type = roomTypes.find((x) => x.id === b.room_type_id);

  const freeRooms = useQuery({
    queryKey: ["available-rooms", org.id, b.check_in, b.check_out, b.room_type_id, b.id],
    enabled: b.status === "new_request" && can("bookings.write"),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("available_rooms", {
        p_tenant: org.id, p_check_in: b.check_in, p_check_out: b.check_out, p_room_type_id: b.room_type_id, p_exclude_booking: b.id,
      });
      if (error) throw error;
      return data as { id: string; number: string }[];
    },
  });

  const change = async (status: BookingStatus, extra: { reason?: string; roomId?: string } = {}) => {
    setBusy(true);
    const { error } = await supabase.rpc("set_booking_status", {
      p_booking_id: b.id, p_status: status, p_reason: extra.reason ?? null, p_room_id: extra.roomId ?? null,
    });
    setBusy(false);
    if (error) { toast.error(describeBookingError(error, t)); return; }
    toast.success(t(`bookings.statusChanged.${status}`));
    invalidateBookings(qc, org.id);
    onClose();
  };

  const canWrite = writable && can("bookings.write");
  const canCheckin = writable && can("bookings.checkin");
  const canCancel = writable && (can("bookings.cancel") || (b.status === "new_request" && can("leads.write")));
  const editable = canWrite && ["new_request", "confirmed", "checked_in"].includes(b.status);

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("bookings.detailsTitle", { number: b.number })} className="max-w-xl">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={bookingStatusVariant[b.status]}>{t(`bookings.status.${b.status}`)}</Badge>
        <span className="text-xs text-muted-foreground">{t(`bookings.source.${b.source}`)} · {formatDateTime(b.created_at, lang, org.timezone)}</span>
      </div>

      <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
        <dt className="text-muted-foreground">{t("bookings.fields.guest")}</dt>
        <dd>
          <span className="font-medium">{b.guest?.full_name}</span>
          {b.guest?.phone && (
            <span className="ml-2 inline-flex gap-2">
              <a className="text-primary hover:underline" href={`tel:${b.guest.phone}`}>{formatKzPhone(b.guest.phone)}</a>
              <a className="text-primary hover:underline" href={whatsappLink(b.guest.phone)} target="_blank" rel="noopener noreferrer">WhatsApp</a>
            </span>
          )}
        </dd>
        <dt className="text-muted-foreground">{t("bookings.fields.dates")}</dt>
        <dd>{formatDate(b.check_in, lang)} — {formatDate(b.check_out, lang)} · {t("bookings.nights", { count: b.nights })}</dd>
        <dt className="text-muted-foreground">{t("bookings.fields.room")}</dt>
        <dd>{type?.name ?? "—"}{room ? `, №${room.number}` : ` · ${t("bookings.noRoomShort")}`}</dd>
        <dt className="text-muted-foreground">{t("bookings.fields.guests")}</dt>
        <dd>{t("bookings.guestsValue", { adults: b.adults, children: b.children })}</dd>
        <dt className="text-muted-foreground">{t("bookings.total")}</dt>
        <dd className="font-semibold">{formatKzt(b.total_amount, lang)}</dd>
        {b.guest_comment && (<><dt className="text-muted-foreground">{t("bookings.fields.comment")}</dt><dd className="whitespace-pre-line">{b.guest_comment}</dd></>)}
        {b.internal_notes && (<><dt className="text-muted-foreground">{t("bookings.fields.internalNotes")}</dt><dd className="whitespace-pre-line">{b.internal_notes}</dd></>)}
        {b.cancel_reason && (<><dt className="text-muted-foreground">{t("bookings.fields.cancelReason")}</dt><dd>{b.cancel_reason}</dd></>)}
      </dl>
      {b.status !== "new_request" && hasFeature("procedures")
        && (can("procedures.read") || can("finance.read") || can("payments.accept")) && <BookingProcedures booking={b} />}
      {b.status !== "new_request" && <BookingPayments booking={b} />}
      <BookingMarketing booking={b} />

      {cancelMode ? (
        <div className="mt-5 grid gap-2 rounded-md border p-3">
          <label htmlFor="cancel-reason" className="text-sm font-medium">
            {cancelMode === "no_show" ? t("bookings.noShowReason") : t("bookings.fields.cancelReason")}
          </label>
          <Input id="cancel-reason" value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} autoFocus />
          <div className="flex justify-end gap-2">
            <Button variant="outline" size="sm" onClick={() => setCancelMode(null)}>{t("common.back")}</Button>
            <Button variant="destructive" size="sm" disabled={busy || (cancelMode === "cancelled" && b.status === "confirmed" && !reason.trim())}
              onClick={() => change(cancelMode, { reason })}>
              {cancelMode === "no_show" ? t("bookings.actions.noShow") : t("bookings.actions.cancel")}
            </Button>
          </div>
        </div>
      ) : (
        <div className="mt-5 flex flex-wrap gap-2">
          {b.status === "new_request" && canWrite && (
            <div className="flex w-full flex-wrap items-center gap-2 rounded-md border p-3">
              <span className="text-sm">{t("bookings.confirmWithRoom")}</span>
              <NativeSelect className="h-8 w-36" value={confirmRoom} onChange={(e) => setConfirmRoom(e.target.value)} aria-label={t("bookings.fields.room")}>
                <option value="">—</option>
                {freeRooms.data?.map((r) => <option key={r.id} value={r.id}>{r.number}</option>)}
              </NativeSelect>
              <Button size="sm" disabled={busy || !confirmRoom} onClick={() => change("confirmed", { roomId: confirmRoom })}>{t("bookings.actions.confirm")}</Button>
              {freeRooms.data?.length === 0 && <span className="text-xs text-destructive">{t("bookings.noFreeRooms")}</span>}
            </div>
          )}
          {b.status === "confirmed" && canCheckin && (
            <Button disabled={busy || b.check_in > today} title={b.check_in > today ? t("bookings.errors.tooEarly") : undefined}
              onClick={() => change("checked_in")}>{t("bookings.actions.checkIn")}</Button>
          )}
          {b.status === "checked_in" && canCheckin && (
            <Button disabled={busy} onClick={() => change("checked_out")}>{t("bookings.actions.checkOut")}</Button>
          )}
          {editable && <Button variant="outline" onClick={onEdit}>{t("common.edit")}</Button>}
          {b.status === "confirmed" && canCheckin && b.check_in <= today && (
            <Button variant="ghost" className="text-destructive" onClick={() => setCancelMode("no_show")}>{t("bookings.actions.noShow")}</Button>
          )}
          {["new_request", "confirmed"].includes(b.status) && canCancel && (
            <Button variant="ghost" className="text-destructive" onClick={() => setCancelMode("cancelled")}>
              {b.status === "new_request" ? t("bookings.actions.decline") : t("bookings.actions.cancel")}
            </Button>
          )}
        </div>
      )}
    </Dialog>
  );
}
