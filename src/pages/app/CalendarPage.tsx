import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { BedDouble, ChevronLeft, ChevronRight } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { formatMonthYear, formatWeekdayShort, todayInTimeZone, type AppLanguage } from "@/lib/format";
import { BOOKING_SELECT, OCCUPYING_STATUSES, addDays, dateRange, diffDays, type Booking, type BookingStatus } from "@/lib/bookings";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";
import { BookingDialog, type BookingPreset } from "@/features/bookings/BookingDialog";
import { BookingDetailsDialog } from "@/features/bookings/BookingDetailsDialog";
import { useRooms, useRoomTypes } from "./RoomsPage";

const CELL = 44;   // ширина дня, px
const ROW = 40;    // высота строки номера, px

const barColor: Partial<Record<BookingStatus, string>> = {
  confirmed: "bg-primary/85 text-primary-foreground",
  checked_in: "bg-success text-white",
  checked_out: "bg-muted-foreground/40 text-foreground",
};

/** Позиция полосы брони в днях от начала периода: от середины дня заезда до середины дня выезда */
export function barPosition(start: string, days: number, checkIn: string, checkOut: string) {
  const from = Math.max(diffDays(start, checkIn) + 0.5, 0);
  const to = Math.min(diffDays(start, checkOut) + 0.5, days);
  return to > from ? { left: from, width: to - from } : null;
}

/** Шахматка: номера × дни, занятость по броням. Клик по свободной клетке — новая бронь. */
export function CalendarPage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable } = useOrg();
  const today = todayInTimeZone(org.timezone);
  const [start, setStart] = useState(addDays(today, -1));
  const [days, setDays] = useState(14);
  const end = addDays(start, days);
  const dates = useMemo(() => dateRange(start, days), [start, days]);

  const types = useRoomTypes(org.id);
  const rooms = useRooms(org.id);
  const bookings = useQuery({
    queryKey: ["calendar", org.id, start, end],
    queryFn: async () => {
      const { data, error } = await supabase.from("bookings").select(BOOKING_SELECT)
        .eq("tenant_id", org.id).in("status", OCCUPYING_STATUSES).not("room_id", "is", null)
        .lt("check_in", end).gt("check_out", start);
      if (error) throw error;
      return data as unknown as Booking[];
    },
  });
  const requests = useQuery({
    queryKey: ["bookings", org.id, "requests-count"],
    queryFn: async () => {
      const { count, error } = await supabase.from("bookings").select("id", { count: "exact", head: true })
        .eq("tenant_id", org.id).eq("status", "new_request");
      if (error) throw error;
      return count ?? 0;
    },
  });

  const [preset, setPreset] = useState<BookingPreset | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [editing, setEditing] = useState<Booking | null>(null);
  const canCreate = can("bookings.write") && writable;

  const asDate = (iso: string) => new Date(`${iso}T00:00:00Z`);

  if (types.error || rooms.error || bookings.error) {
    const err = types.error ?? rooms.error ?? bookings.error;
    return <ErrorState error={err} onRetry={() => { void types.refetch(); void rooms.refetch(); void bookings.refetch(); }} />;
  }

  const activeRooms = (rooms.data ?? []).filter((r) => r.is_active);
  const groups = (types.data ?? []).map((rt) => ({ type: rt, rooms: activeRooms.filter((r) => r.room_type_id === rt.id) }))
    .filter((g) => g.rooms.length > 0);
  const byRoom = new Map<string, Booking[]>();
  for (const b of bookings.data ?? []) byRoom.set(b.room_id!, [...(byRoom.get(b.room_id!) ?? []), b]);
  const opened = bookings.data?.find((b) => b.id === openId) ?? null;

  return (
    <>
      <PageHeader title={t("calendar.title")} description={formatMonthYear(start, lang)} />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Button variant="outline" size="icon" aria-label={t("calendar.prev")} onClick={() => setStart(addDays(start, -7))}><ChevronLeft /></Button>
        <Button variant="outline" onClick={() => setStart(addDays(today, -1))}>{t("calendar.today")}</Button>
        <Button variant="outline" size="icon" aria-label={t("calendar.next")} onClick={() => setStart(addDays(start, 7))}><ChevronRight /></Button>
        <Input type="date" className="w-40" value={start} aria-label={t("calendar.from")} onChange={(e) => e.target.value && setStart(e.target.value)} />
        <NativeSelect className="w-32" value={days} aria-label={t("calendar.period")} onChange={(e) => setDays(Number(e.target.value))}>
          <option value={14}>{t("calendar.days", { count: 14 })}</option>
          <option value={31}>{t("calendar.days", { count: 31 })}</option>
        </NativeSelect>
        {(requests.data ?? 0) > 0 && (
          <Link to="../bookings?tab=requests" relative="path" className="ml-auto text-sm font-medium text-warning hover:underline">
            {t("calendar.requests", { count: requests.data })}
          </Link>
        )}
      </div>

      {types.isLoading || rooms.isLoading ? (
        <Skeleton className="h-64" />
      ) : groups.length === 0 ? (
        <EmptyState icon={<BedDouble className="h-5 w-5" />} title={t("calendar.noRooms")}
          action={can("rooms.write") && <Button asChild className="mt-2"><Link to="../rooms" relative="path">{t("calendar.toRooms")}</Link></Button>} />
      ) : (
        <div className="overflow-x-auto rounded-lg border bg-card">
          <div style={{ width: 112 + days * CELL }} className="text-xs">
            {/* заголовок с датами */}
            <div className="sticky top-0 z-10 flex border-b bg-card">
              <div className="sticky left-0 z-20 w-28 shrink-0 border-r bg-card" />
              {dates.map((d) => {
                const wd = asDate(d).getUTCDay();
                return (
                  <div key={d} style={{ width: CELL }}
                    className={cn("shrink-0 border-r py-1.5 text-center", (wd === 0 || wd === 6) && "bg-muted/60", d === today && "bg-accent font-semibold text-accent-foreground")}>
                    <div className="text-sm">{Number(d.slice(8, 10))}</div>
                    <div className="text-[10px] uppercase text-muted-foreground">{formatWeekdayShort(d, lang)}</div>
                  </div>
                );
              })}
            </div>

            {groups.map((g) => (
              <div key={g.type.id}>
                <div className="sticky left-0 border-b bg-muted/40 px-3 py-1 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground" style={{ width: 112 + days * CELL }}>
                  {g.type.name}
                </div>
                {g.rooms.map((room) => (
                  <div key={room.id} className="flex border-b last:border-b-0" style={{ height: ROW }}>
                    <div className="sticky left-0 z-[5] flex w-28 shrink-0 items-center gap-1.5 border-r bg-card px-3">
                      <span className="font-medium">{room.number}</span>
                      {room.status !== "available" && room.status !== "occupied" && (
                        <span className={cn("h-2 w-2 rounded-full", room.status === "cleaning" ? "bg-warning" : "bg-destructive")}
                          title={t(`rooms.status.${room.status}`)} />
                      )}
                    </div>
                    <div className="relative flex">
                      {dates.map((d) => {
                        const wd = asDate(d).getUTCDay();
                        return (
                          <button key={d} type="button" style={{ width: CELL }} disabled={!canCreate || d < today}
                            aria-label={t("calendar.newAt", { room: room.number, date: d })}
                            className={cn("shrink-0 border-r enabled:hover:bg-accent/60", (wd === 0 || wd === 6) && "bg-muted/30", d === today && "bg-accent/40")}
                            onClick={() => setPreset({ room_id: room.id, room_type_id: room.room_type_id, check_in: d })} />
                        );
                      })}
                      {(byRoom.get(room.id) ?? []).map((b) => {
                        const pos = barPosition(start, days, b.check_in, b.check_out);
                        if (!pos) return null;
                        return (
                          <button key={b.id} type="button" onClick={() => setOpenId(b.id)}
                            title={`№${b.number} · ${b.guest?.full_name ?? ""}`}
                            className={cn("absolute top-1.5 truncate rounded px-1.5 text-left text-[11px] font-medium leading-7 shadow-sm hover:ring-2 hover:ring-ring", barColor[b.status])}
                            style={{ left: pos.left * CELL + 1, width: pos.width * CELL - 2, height: ROW - 12 }}>
                            {b.guest?.full_name}
                          </button>
                        );
                      })}
                    </div>
                  </div>
                ))}
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="mt-3 flex flex-wrap gap-4 text-xs text-muted-foreground">
        <span className="flex items-center gap-1.5"><span className="h-3 w-5 rounded bg-primary/85" />{t("bookings.status.confirmed")}</span>
        <span className="flex items-center gap-1.5"><span className="h-3 w-5 rounded bg-success" />{t("bookings.status.checked_in")}</span>
        <span className="flex items-center gap-1.5"><span className="h-3 w-5 rounded bg-muted-foreground/40" />{t("bookings.status.checked_out")}</span>
        <span className="flex items-center gap-1.5"><span className="h-2 w-2 rounded-full bg-warning" />{t("rooms.status.cleaning")}</span>
        <span className="flex items-center gap-1.5"><span className="h-2 w-2 rounded-full bg-destructive" />{t("rooms.status.maintenance")}</span>
      </div>

      {preset && types.data && <BookingDialog preset={preset} roomTypes={types.data} onClose={() => setPreset(null)} />}
      {editing && types.data && <BookingDialog booking={editing} roomTypes={types.data} onClose={() => setEditing(null)} />}
      {opened && types.data && rooms.data && (
        <BookingDetailsDialog booking={opened} rooms={rooms.data} roomTypes={types.data}
          onEdit={() => { setEditing(opened); setOpenId(null); }} onClose={() => setOpenId(null)} />
      )}
    </>
  );
}
