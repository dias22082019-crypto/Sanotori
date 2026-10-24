import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { ClipboardList, Plus } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { formatDate, formatKzt, todayInTimeZone, type AppLanguage } from "@/lib/format";
import { BOOKING_SELECT, bookingStatusVariant, type Booking } from "@/lib/bookings";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";
import { BookingDialog } from "@/features/bookings/BookingDialog";
import { BookingDetailsDialog } from "@/features/bookings/BookingDetailsDialog";
import { useRooms, useRoomTypes } from "./RoomsPage";

const TABS = ["requests", "arrivals", "in_house", "upcoming", "all"] as const;
type Tab = (typeof TABS)[number];

/** Список бронирований с вкладками: заявки, заезды сегодня, проживают, предстоящие, все */
export function BookingsPage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable } = useOrg();
  const today = todayInTimeZone(org.timezone);
  const [params, setParams] = useSearchParams();
  const tab = (TABS as readonly string[]).includes(params.get("tab") ?? "") ? (params.get("tab") as Tab) : "upcoming";
  const [creating, setCreating] = useState(false);
  const [openId, setOpenId] = useState<string | null>(null);
  const [editing, setEditing] = useState<Booking | null>(null);

  const types = useRoomTypes(org.id);
  const rooms = useRooms(org.id);
  const bookings = useQuery({
    queryKey: ["bookings", org.id, tab, today],
    queryFn: async () => {
      let q = supabase.from("bookings").select(BOOKING_SELECT).eq("tenant_id", org.id);
      if (tab === "requests") q = q.eq("status", "new_request").order("created_at", { ascending: false });
      if (tab === "arrivals") q = q.eq("status", "confirmed").eq("check_in", today).order("number");
      if (tab === "in_house") q = q.eq("status", "checked_in").order("check_out");
      if (tab === "upcoming") q = q.eq("status", "confirmed").gte("check_in", today).order("check_in");
      if (tab === "all") q = q.order("check_in", { ascending: false });
      const { data, error } = await q.limit(200);
      if (error) throw error;
      return data as unknown as Booking[];
    },
  });

  const seesPayments = can("finance.read") || can("payments.accept");
  const ids = bookings.data?.map((b) => b.id) ?? [];
  const balances = useQuery({
    queryKey: ["bookings", org.id, "balances", ids],
    enabled: seesPayments && ids.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase.from("booking_balances").select("booking_id, balance").in("booking_id", ids);
      if (error) throw error;
      return new Map((data ?? []).map((r) => [r.booking_id as string, Number(r.balance)]));
    },
  });

  const roomNumber = (id: string | null) => rooms.data?.find((r) => r.id === id)?.number;
  const typeName = (id: string) => types.data?.find((x) => x.id === id)?.name ?? "";
  const opened = bookings.data?.find((b) => b.id === openId) ?? null;
  const canCreate = can("bookings.write") && writable && (types.data?.length ?? 0) > 0;

  return (
    <>
      <PageHeader
        title={t("bookings.title")}
        actions={canCreate && <Button onClick={() => setCreating(true)}><Plus /> {t("bookings.new")}</Button>}
      />

      <div className="-mx-4 mb-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
        <div role="tablist" className="inline-flex gap-1 rounded-lg bg-muted p-1">
          {TABS.map((key) => (
            <button key={key} role="tab" aria-selected={tab === key}
              className={cn("whitespace-nowrap rounded-md px-3 py-1.5 text-sm", tab === key ? "bg-card font-medium shadow-sm" : "text-muted-foreground hover:text-foreground")}
              onClick={() => setParams({ tab: key }, { replace: true })}>
              {t(`bookings.tabs.${key}`)}
            </button>
          ))}
        </div>
      </div>

      {bookings.isLoading || types.isLoading ? (
        <div className="grid gap-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-12" />)}</div>
      ) : bookings.error ? (
        <ErrorState error={bookings.error} onRetry={() => bookings.refetch()} />
      ) : bookings.data!.length === 0 ? (
        <EmptyState icon={<ClipboardList className="h-5 w-5" />} title={t(`bookings.empty.${tab}`)}
          text={(types.data?.length ?? 0) === 0 ? t("bookings.needRooms") : undefined} />
      ) : (
        <Card>
          <CardContent className="pt-5">
            {/* Телефон: карточки вместо широкой таблицы */}
            <ul className="-mx-5 -mt-5 divide-y md:hidden">
              {bookings.data!.map((b) => (
                <li key={b.id}>
                  <button type="button" className="grid w-full gap-1 px-5 py-3 text-left hover:bg-muted/50" onClick={() => setOpenId(b.id)}>
                    <span className="flex items-start justify-between gap-3">
                      <span className="font-medium">{b.guest?.full_name}</span>
                      <Badge variant={bookingStatusVariant[b.status]}>{t(`bookings.status.${b.status}`)}</Badge>
                    </span>
                    <span className="text-sm">
                      {formatDate(b.check_in, lang)} — {formatDate(b.check_out, lang)}
                      <span className="text-muted-foreground"> · {t("bookings.nights", { count: b.nights })}</span>
                    </span>
                    <span className="flex items-center justify-between gap-3 text-xs text-muted-foreground">
                      <span>№{b.number} · {roomNumber(b.room_id) ?? t("bookings.noRoomShort")} · {typeName(b.room_type_id)}</span>
                      <span className="whitespace-nowrap text-sm">
                        {seesPayments ? <DueCell value={balances.data?.get(b.id)} lang={lang} /> : <span className="text-foreground">{formatKzt(b.total_amount, lang)}</span>}
                      </span>
                    </span>
                  </button>
                </li>
              ))}
            </ul>
            <div className="-mx-5 hidden overflow-x-auto md:block">
              <table className="w-full min-w-[720px] text-sm">
                <thead>
                  <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
                    <th className="px-5 py-2 font-medium">№</th>
                    <th className="px-5 py-2 font-medium">{t("bookings.fields.guest")}</th>
                    <th className="px-5 py-2 font-medium">{t("bookings.fields.dates")}</th>
                    <th className="px-5 py-2 font-medium">{t("bookings.fields.room")}</th>
                    <th className="px-5 py-2 font-medium">{t("bookings.colStatus")}</th>
                    <th className="px-5 py-2 text-right font-medium">{t("bookings.total")}</th>
                    {seesPayments && <th className="px-5 py-2 text-right font-medium">{t("finance.due")}</th>}
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {bookings.data!.map((b) => (
                    <tr key={b.id} className="cursor-pointer hover:bg-muted/50" onClick={() => setOpenId(b.id)}>
                      <td className="px-5 py-2.5 text-muted-foreground">{b.number}</td>
                      <td className="px-5 py-2.5 font-medium">{b.guest?.full_name}</td>
                      <td className="px-5 py-2.5 whitespace-nowrap">
                        {formatDate(b.check_in, lang)} — {formatDate(b.check_out, lang)}
                        <span className="block text-xs text-muted-foreground">{t("bookings.nights", { count: b.nights })}</span>
                      </td>
                      <td className="px-5 py-2.5">
                        {roomNumber(b.room_id) ?? <span className="text-muted-foreground">{t("bookings.noRoomShort")}</span>}
                        <span className="block text-xs text-muted-foreground">{typeName(b.room_type_id)}</span>
                      </td>
                      <td className="px-5 py-2.5"><Badge variant={bookingStatusVariant[b.status]}>{t(`bookings.status.${b.status}`)}</Badge></td>
                      <td className="px-5 py-2.5 text-right whitespace-nowrap">{formatKzt(b.total_amount, lang)}</td>
                      {seesPayments && (
                        <td className="px-5 py-2.5 text-right whitespace-nowrap">
                          <DueCell value={balances.data?.get(b.id)} lang={lang} />
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </CardContent>
        </Card>
      )}

      {creating && types.data && <BookingDialog roomTypes={types.data} onClose={() => setCreating(false)} />}
      {editing && types.data && <BookingDialog booking={editing} roomTypes={types.data} onClose={() => setEditing(null)} />}
      {opened && types.data && rooms.data && (
        <BookingDetailsDialog booking={opened} rooms={rooms.data} roomTypes={types.data}
          onEdit={() => { setEditing(opened); setOpenId(null); }} onClose={() => setOpenId(null)} />
      )}
    </>
  );
}

function DueCell({ value, lang }: { value: number | undefined; lang: AppLanguage }) {
  if (value === undefined) return <span className="text-muted-foreground">…</span>;
  if (value === 0) return <span className="text-success">0 ₸</span>;
  return <span className={value > 0 ? "font-medium text-destructive" : "text-warning"}>{value < 0 ? "−" : ""}{formatKzt(Math.abs(value), lang)}</span>;
}
