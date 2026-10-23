import { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Plus, X } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { formatKzPhone, formatKzt, todayInTimeZone, type AppLanguage } from "@/lib/format";
import {
  BOOKING_SOURCES, addDays, describeBookingError, diffDays,
  type Booking, type BookingSource, type Guest, type Quote, type RoomType,
} from "@/lib/bookings";
import { useOrg } from "@/auth/OrgProvider";
import { useGuestSearch, GuestDialog } from "@/pages/app/GuestsPage";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect, Textarea } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";

export interface BookingPreset {
  room_id?: string;
  room_type_id?: string;
  check_in?: string;
}

interface AvailableRoom { id: string; number: string; floor: string | null; room_type_id: string }

/** Сброс кэша всего, что зависит от бронирований */
export function invalidateBookings(qc: ReturnType<typeof useQueryClient>, tenantId: string) {
  for (const key of ["bookings", "calendar", "today-summary", "rooms", "available-rooms"]) {
    void qc.invalidateQueries({ queryKey: [key, tenantId] });
  }
  void qc.invalidateQueries({ queryKey: ["guest-bookings"] });
}

/**
 * Создание или изменение брони. Сумма показывается из quote_booking() и при сохранении
 * пересчитывается сервером: клиент цену не передаёт.
 */
export function BookingDialog({ booking, preset, roomTypes, onClose }: {
  booking?: Booking | null;
  preset?: BookingPreset;
  roomTypes: RoomType[];
  onClose: () => void;
}) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const today = todayInTimeZone(org.timezone);
  const activeTypes = roomTypes.filter((x) => x.is_active || x.id === booking?.room_type_id);

  const [guest, setGuest] = useState<Pick<Guest, "id" | "full_name" | "phone"> | null>(booking?.guest ?? null);
  const [checkIn, setCheckIn] = useState(booking?.check_in ?? preset?.check_in ?? today);
  const [checkOut, setCheckOut] = useState(booking?.check_out ?? addDays(preset?.check_in ?? today, 1));
  const [adults, setAdults] = useState(booking?.adults ?? 1);
  const [children, setChildren] = useState(booking?.children ?? 0);
  const [typeId, setTypeId] = useState(booking?.room_type_id ?? preset?.room_type_id ?? activeTypes[0]?.id ?? "");
  const [roomId, setRoomId] = useState(booking?.room_id ?? preset?.room_id ?? "");
  const [source, setSource] = useState<BookingSource>(booking?.source ?? "phone");
  const [comment, setComment] = useState(booking?.guest_comment ?? "");
  const [notes, setNotes] = useState(booking?.internal_notes ?? "");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const nights = diffDays(checkIn, checkOut);
  const datesValid = Boolean(checkIn && checkOut) && nights > 0 && nights <= 365;

  const rooms = useQuery({
    queryKey: ["available-rooms", org.id, checkIn, checkOut, typeId, booking?.id],
    enabled: datesValid && Boolean(typeId),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("available_rooms", {
        p_tenant: org.id, p_check_in: checkIn, p_check_out: checkOut, p_room_type_id: typeId, p_exclude_booking: booking?.id ?? null,
      });
      if (error) throw error;
      return data as AvailableRoom[];
    },
  });

  // выбранный номер стал недоступен на новые даты — сбрасываем выбор
  useEffect(() => {
    if (roomId && rooms.data && !rooms.data.some((r) => r.id === roomId)) setRoomId("");
  }, [rooms.data, roomId]);

  const quote = useQuery({
    queryKey: ["quote", org.id, typeId, checkIn, checkOut, adults, children],
    enabled: datesValid && Boolean(typeId) && adults >= 1,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("quote_booking", {
        p_tenant: org.id, p_room_type_id: typeId, p_check_in: checkIn, p_check_out: checkOut, p_adults: adults, p_children: children,
      });
      if (error) throw error;
      return data as Quote;
    },
  });

  const selectedType = activeTypes.find((x) => x.id === typeId);
  const overCapacity = selectedType ? adults + children > selectedType.max_occupancy : false;

  const save = async () => {
    setError(null);
    if (!guest) return setError(t("bookings.errors.guestRequired"));
    if (!datesValid) return setError(t("bookings.errors.dates"));
    if (!typeId) return setError(t("bookings.errors.typeRequired"));
    if (overCapacity) return setError(t("bookings.errors.capacity"));
    if (booking && booking.status !== "new_request" && !roomId) return setError(t("bookings.errors.roomRequired"));
    setSaving(true);
    const { error } = booking
      ? await supabase.rpc("update_booking", {
          p_booking_id: booking.id, p_room_type_id: typeId, p_room_id: roomId || null, p_check_in: checkIn, p_check_out: checkOut,
          p_adults: adults, p_children: children, p_comment: comment, p_internal_notes: notes,
        })
      : await supabase.rpc("create_booking", {
          p_tenant: org.id, p_guest_id: guest.id, p_room_type_id: typeId, p_room_id: roomId || null,
          p_check_in: checkIn, p_check_out: checkOut, p_adults: adults, p_children: children,
          p_source: source, p_comment: comment, p_status: roomId ? "confirmed" : "new_request",
        });
    setSaving(false);
    if (error) return setError(describeBookingError(error, t));
    toast.success(booking ? t("common.saved") : roomId ? t("bookings.created") : t("bookings.createdRequest"));
    invalidateBookings(qc, org.id);
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} className="max-w-xl"
      title={booking ? t("bookings.editTitle", { number: booking.number }) : t("bookings.newTitle")}>
      <div className="grid gap-3">
        {booking ? (
          <p className="text-sm"><span className="text-muted-foreground">{t("bookings.fields.guest")}:</span> <span className="font-medium">{booking.guest?.full_name}</span></p>
        ) : (
          <GuestPicker value={guest} onChange={setGuest} />
        )}

        <div className="grid grid-cols-2 gap-3">
          <FormField id="b-in" label={t("bookings.fields.checkIn")}>
            <Input id="b-in" type="date" value={checkIn} disabled={booking?.status === "checked_in"}
              onChange={(e) => {
                const v = e.target.value;
                setCheckIn(v);
                if (v && (!checkOut || checkOut <= v)) setCheckOut(addDays(v, 1));
              }} />
          </FormField>
          <FormField id="b-out" label={t("bookings.fields.checkOut")} hint={datesValid ? t("bookings.nights", { count: nights }) : undefined}>
            <Input id="b-out" type="date" min={checkIn ? addDays(checkIn, 1) : undefined} value={checkOut} onChange={(e) => setCheckOut(e.target.value)} />
          </FormField>
          <FormField id="b-adults" label={t("bookings.fields.adults")}>
            <Input id="b-adults" type="number" min={1} max={30} value={adults} onChange={(e) => setAdults(Math.max(1, Number(e.target.value) || 1))} />
          </FormField>
          <FormField id="b-children" label={t("bookings.fields.children")}>
            <Input id="b-children" type="number" min={0} max={30} value={children} onChange={(e) => setChildren(Math.max(0, Number(e.target.value) || 0))} />
          </FormField>
          <FormField id="b-type" label={t("bookings.fields.roomType")}
            error={overCapacity ? t("bookings.errors.capacityMax", { max: selectedType?.max_occupancy }) : undefined}>
            <NativeSelect id="b-type" value={typeId} onChange={(e) => { setTypeId(e.target.value); setRoomId(""); }}>
              {activeTypes.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="b-room" label={t("bookings.fields.room")}
            hint={rooms.data && rooms.data.length === 0 ? t("bookings.noFreeRooms") : !roomId && !booking ? t("bookings.noRoomHint") : undefined}>
            <NativeSelect id="b-room" value={roomId} onChange={(e) => setRoomId(e.target.value)} disabled={!datesValid}>
              <option value="">{booking && booking.status !== "new_request" ? "—" : t("bookings.noRoom")}</option>
              {rooms.data?.map((r) => <option key={r.id} value={r.id}>{r.number}{r.floor ? ` · ${t("rooms.fields.floor").toLowerCase()} ${r.floor}` : ""}</option>)}
            </NativeSelect>
          </FormField>
        </div>

        {!booking && (
          <FormField id="b-source" label={t("bookings.fields.source")}>
            <NativeSelect id="b-source" value={source} onChange={(e) => setSource(e.target.value as BookingSource)}>
              {BOOKING_SOURCES.map((s) => <option key={s} value={s}>{t(`bookings.source.${s}`)}</option>)}
            </NativeSelect>
          </FormField>
        )}
        <FormField id="b-comment" label={`${t("bookings.fields.comment")} (${t("common.optional")})`}>
          <Textarea id="b-comment" rows={2} value={comment} maxLength={2000} onChange={(e) => setComment(e.target.value)} />
        </FormField>
        {booking && (
          <FormField id="b-notes" label={`${t("bookings.fields.internalNotes")} (${t("common.optional")})`}>
            <Textarea id="b-notes" rows={2} value={notes} maxLength={2000} onChange={(e) => setNotes(e.target.value)} />
          </FormField>
        )}

        <div className="flex items-center justify-between rounded-md bg-accent px-3 py-2 text-sm">
          <span>{t("bookings.total")}</span>
          <span className="text-base font-semibold">
            {quote.data ? formatKzt(quote.data.total, lang) : quote.isFetching ? "…" : "—"}
          </span>
        </div>
        <p className="-mt-1 text-xs text-muted-foreground">{t("bookings.totalHint")}</p>

        {error && <p role="alert" className="rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm text-destructive">{error}</p>}
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="button" onClick={save} disabled={saving}>
            {saving ? t("common.saving") : booking ? t("common.save") : roomId ? t("bookings.createConfirmed") : t("bookings.createRequest")}
          </Button>
        </DialogFooter>
      </div>
    </Dialog>
  );
}

function GuestPicker({ value, onChange }: {
  value: Pick<Guest, "id" | "full_name" | "phone"> | null;
  onChange: (g: Pick<Guest, "id" | "full_name" | "phone"> | null) => void;
}) {
  const { t } = useTranslation();
  const { org, can } = useOrg();
  const [term, setTerm] = useState("");
  const [creating, setCreating] = useState(false);
  const enabled = term.trim().length >= 2;
  const results = useGuestSearch(org.id, term, enabled);
  const list = useMemo(() => (enabled ? results.data ?? [] : []), [enabled, results.data]);

  if (value) {
    return (
      <div className="grid gap-1.5">
        <span className="text-sm font-medium">{t("bookings.fields.guest")}</span>
        <div className="flex items-center justify-between rounded-md border px-3 py-2 text-sm">
          <span><span className="font-medium">{value.full_name}</span>{value.phone && <span className="ml-2 text-muted-foreground">{formatKzPhone(value.phone)}</span>}</span>
          <Button size="icon" variant="ghost" className="h-7 w-7" aria-label={t("bookings.changeGuest")} onClick={() => onChange(null)}><X /></Button>
        </div>
      </div>
    );
  }

  return (
    <div className="grid gap-1.5">
      <label htmlFor="b-guest" className="text-sm font-medium">{t("bookings.fields.guest")}</label>
      <div className="flex gap-2">
        <Input id="b-guest" autoComplete="off" placeholder={t("bookings.guestSearch")} value={term} onChange={(e) => setTerm(e.target.value)} />
        {can("guests.write") && (
          <Button type="button" variant="outline" onClick={() => setCreating(true)}><Plus /> {t("bookings.newGuest")}</Button>
        )}
      </div>
      {enabled && (
        <ul className="max-h-48 overflow-y-auto rounded-md border text-sm">
          {results.isLoading ? <li className="px-3 py-2 text-muted-foreground">{t("common.loading")}</li> :
            list.length === 0 ? <li className="px-3 py-2 text-muted-foreground">{t("guests.notFound")}</li> :
              list.slice(0, 8).map((g) => (
                <li key={g.id}>
                  <button type="button" className="flex w-full justify-between px-3 py-2 text-left hover:bg-muted" onClick={() => onChange(g)}>
                    <span>{g.full_name}</span>
                    <span className="text-muted-foreground">{g.phone ? formatKzPhone(g.phone) : ""}</span>
                  </button>
                </li>
              ))}
        </ul>
      )}
      {creating && (
        <GuestDialog value={null} initialName={/\d/.test(term) ? "" : term} onClose={() => setCreating(false)} onSaved={(g) => onChange(g)} />
      )}
    </div>
  );
}
