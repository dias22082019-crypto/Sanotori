import { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Link, useSearchParams } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Inbox, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import {
  dateInTimeZone, formatDate, formatDateTime, formatKzPhone, formatTime, todayInTimeZone, whatsappLink, zonedDateTime,
  type AppLanguage,
} from "@/lib/format";
import { optionalGuestPhone } from "@/lib/schemas";
import { BOOKING_SELECT, BOOKING_SOURCES, type Booking, type BookingSource } from "@/lib/bookings";
import {
  LEAD_SELECT, LEAD_TABS, LOST_REASONS, describeLeadError, isContactOverdue, isLeadOpen, leadStatusVariant, leadStatusesFor, sortLeads,
  type Lead, type LeadCounts, type LeadLostReason, type LeadNote, type LeadTab,
} from "@/lib/leads";
import { useStaff } from "@/lib/procedures";
import { cn } from "@/lib/utils";
import { useAuth } from "@/auth/AuthProvider";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect, Textarea } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";
import { BookingDialog } from "@/features/bookings/BookingDialog";
import { BookingDetailsDialog } from "@/features/bookings/BookingDetailsDialog";
import { useRooms, useRoomTypes } from "./RoomsPage";

/** Счётчики заявок: новые, открытые, «пора связаться», мои */
export function useLeadCounts(tenantId: string, enabled = true) {
  return useQuery({
    queryKey: ["lead-counts", tenantId],
    enabled,
    retry: false,
    refetchInterval: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("lead_counts", { p_tenant: tenantId });
      if (error) throw error;
      return data as LeadCounts;
    },
  });
}

/** Заявки: обращения до брони со статусом, ответственным и датой следующего контакта */
export function LeadsPage() {
  const { t } = useTranslation();
  const { org, can, writable } = useOrg();
  const [params, setParams] = useSearchParams();
  const tab: LeadTab = (LEAD_TABS as readonly string[]).includes(params.get("tab") ?? "") ? (params.get("tab") as LeadTab) : "open";
  const openId = params.get("lead");
  const canWrite = writable && can("leads.write");
  const [source, setSource] = useState<BookingSource | "">("");
  const [mine, setMine] = useState(false);
  const [search, setSearch] = useState("");
  const [editing, setEditing] = useState<Lead | "new" | null>(null);
  const [converting, setConverting] = useState<Lead | null>(null);

  const types = useRoomTypes(org.id);
  const staff = useStaff(org.id, "leads.write");
  const counts = useLeadCounts(org.id);
  const leads = useQuery({
    queryKey: ["leads", org.id, tab],
    queryFn: async () => {
      let q = supabase.from("leads").select(LEAD_SELECT).eq("tenant_id", org.id);
      const statuses = leadStatusesFor(tab);
      if (statuses) q = q.in("status", statuses);
      const { data, error } = await q.order("created_at", { ascending: false }).limit(300);
      if (error) throw error;
      return data as unknown as Lead[];
    },
  });
  const opened = useQuery({
    queryKey: ["leads", org.id, "one", openId],
    enabled: Boolean(openId),
    queryFn: async () => {
      const { data, error } = await supabase.from("leads").select(LEAD_SELECT).eq("id", openId!).maybeSingle();
      if (error) throw error;
      return data as unknown as Lead | null;
    },
  });

  const me = useAuth().user?.id;

  const list = useMemo(() => {
    const term = search.trim().toLowerCase();
    const digits = term.replace(/\D/g, "");
    const filtered = (leads.data ?? []).filter((l) =>
      (!source || l.source === source) && (!mine || l.assignee_id === me)
      && (!term || (l.full_name ?? "").toLowerCase().includes(term) || (digits.length >= 3 && (l.phone ?? "").includes(digits))
        || String(l.number) === term));
    return sortLeads(filtered);
  }, [leads.data, source, mine, search, me]);

  const staffName = (id: string | null) => (id ? staff.data?.find((s) => s.user_id === id)?.full_name ?? "—" : null);
  const typeName = (id: string | null) => (id ? types.data?.find((x) => x.id === id)?.name ?? null : null);
  const open = (id: string | null) => {
    const next = new URLSearchParams(params);
    if (id) next.set("lead", id); else next.delete("lead");
    setParams(next, { replace: !id });
  };
  const setTab = (key: LeadTab) => setParams(key === "open" ? {} : { tab: key }, { replace: true });
  const c = counts.data;

  return (
    <>
      <PageHeader title={t("leads.title")} description={t("leads.subtitle")}
        actions={canWrite && <Button onClick={() => setEditing("new")}><Plus /> {t("leads.new")}</Button>} />

      {c && (c.overdue > 0 || c.new > 0) && (
        <div className="mb-4 flex flex-wrap gap-2 text-sm">
          {c.new > 0 && <Badge>{t("leads.countNew", { count: c.new })}</Badge>}
          {c.overdue > 0 && <Badge variant="destructive">{t("leads.countOverdue", { count: c.overdue })}</Badge>}
        </div>
      )}

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <div className="-mx-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
          <div role="tablist" className="inline-flex gap-1 rounded-lg bg-muted p-1">
            {LEAD_TABS.map((key) => (
              <button key={key} role="tab" aria-selected={tab === key}
                className={cn("whitespace-nowrap rounded-md px-3 py-1.5 text-sm", tab === key ? "bg-card font-medium shadow-sm" : "text-muted-foreground hover:text-foreground")}
                onClick={() => setTab(key)}>
                {t(`leads.tabs.${key}`)}{key === "open" && c ? ` · ${c.open}` : ""}
              </button>
            ))}
          </div>
        </div>
        <Input className="h-9 w-full sm:w-56" placeholder={t("leads.search")} aria-label={t("leads.search")} value={search} onChange={(e) => setSearch(e.target.value)} />
        <NativeSelect className="h-9 w-auto" aria-label={t("leads.fields.source")} value={source} onChange={(e) => setSource(e.target.value as BookingSource | "")}>
          <option value="">{t("leads.allSources")}</option>
          {BOOKING_SOURCES.map((s) => <option key={s} value={s}>{t(`bookings.source.${s}`)}</option>)}
        </NativeSelect>
        <label className="flex items-center gap-2 text-sm">
          <Checkbox checked={mine} onCheckedChange={(v) => setMine(v === true)} /> {t("leads.onlyMine")}
        </label>
      </div>

      {leads.error ? (
        <ErrorState error={leads.error} onRetry={() => leads.refetch()} />
      ) : leads.isLoading ? (
        <div className="grid gap-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-16" />)}</div>
      ) : list.length === 0 ? (
        <EmptyState icon={<Inbox className="h-5 w-5" />} title={t(leads.data?.length ? "leads.emptyFiltered" : "leads.emptyTitle")} text={t("leads.emptyText")}
          action={canWrite && !leads.data?.length ? <Button variant="outline" onClick={() => setEditing("new")}><Plus /> {t("leads.new")}</Button> : undefined} />
      ) : (
        <>
          <ul className="grid gap-2 md:hidden">
            {list.map((l) => (
              <li key={l.id}>
                <button className="w-full rounded-lg border bg-card p-3 text-left hover:bg-muted/40" onClick={() => open(l.id)}>
                  <LeadSummary lead={l} typeName={typeName(l.room_type_id)} assignee={staffName(l.assignee_id)} />
                </button>
              </li>
            ))}
          </ul>
          <Card className="hidden md:block">
            <CardContent className="p-0">
              <table className="w-full text-sm">
                <thead className="border-b text-left text-xs text-muted-foreground">
                  <tr>
                    <th className="px-4 py-2 font-medium">№</th>
                    <th className="px-4 py-2 font-medium">{t("leads.fields.contact")}</th>
                    <th className="px-4 py-2 font-medium">{t("leads.fields.wishes")}</th>
                    <th className="px-4 py-2 font-medium">{t("leads.fields.assignee")}</th>
                    <th className="px-4 py-2 font-medium">{t("leads.fields.nextContact")}</th>
                    <th className="px-4 py-2 font-medium">{t("leads.fields.status")}</th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {list.map((l) => (
                    <tr key={l.id} className="cursor-pointer hover:bg-muted/40" onClick={() => open(l.id)}>
                      <td className="px-4 py-2.5 text-muted-foreground">{l.number}</td>
                      <td className="px-4 py-2.5">
                        <div className="font-medium">{l.full_name ?? t("leads.noName")}</div>
                        <div className="whitespace-nowrap text-xs text-muted-foreground">
                          {l.phone ? formatKzPhone(l.phone) : "—"} · {t(`bookings.source.${l.source}`)}
                        </div>
                      </td>
                      <td className="px-4 py-2.5 text-muted-foreground"><Wishes lead={l} typeName={typeName(l.room_type_id)} /></td>
                      <td className="px-4 py-2.5">{staffName(l.assignee_id) ?? <span className="text-muted-foreground">{t("leads.unassigned")}</span>}</td>
                      <td className="px-4 py-2.5"><NextContact lead={l} /></td>
                      <td className="px-4 py-2.5"><LeadStatusBadge lead={l} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </CardContent>
          </Card>
        </>
      )}

      {openId && opened.data && (
        <LeadDetailsDialog lead={opened.data} canWrite={canWrite} typeName={typeName(opened.data.room_type_id)}
          assignee={staffName(opened.data.assignee_id)} onClose={() => open(null)}
          onEdit={() => setEditing(opened.data!)} onConvert={() => setConverting(opened.data!)} />
      )}
      {editing && (
        <LeadDialog value={editing === "new" ? null : editing} staff={staff.data ?? []} roomTypes={types.data ?? []}
          onClose={() => setEditing(null)} onSaved={(id) => { setEditing(null); if (editing === "new") open(id); }} />
      )}
      {converting && types.data && <BookingDialog lead={converting} roomTypes={types.data} onClose={() => setConverting(null)} />}
    </>
  );
}

function LeadStatusBadge({ lead }: { lead: Lead }) {
  const { t } = useTranslation();
  return <Badge className="whitespace-nowrap" variant={leadStatusVariant[lead.status]}>{t(`leads.status.${lead.status}`)}</Badge>;
}

function Wishes({ lead, typeName, full }: { lead: Lead; typeName: string | null; full?: boolean }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const parts = [
    lead.check_in ? `${formatDate(lead.check_in, lang)}${lead.check_out ? ` — ${formatDate(lead.check_out, lang)}` : ""}` : null,
    lead.adults ? t("bookings.guestsValue", { adults: lead.adults, children: lead.children ?? 0 }) : null,
    typeName,
    lead.interest,
  ].filter(Boolean);
  return <span className={full ? undefined : "line-clamp-2"}>{parts.length ? parts.join(" · ") : "—"}</span>;
}

function NextContact({ lead }: { lead: Lead }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  if (!lead.next_contact_at || !isLeadOpen(lead)) return <span className="text-muted-foreground">—</span>;
  const late = isContactOverdue(lead);
  return (
    <span className={cn("whitespace-nowrap", late && "font-medium text-destructive")}>
      {formatDateTime(lead.next_contact_at, lang, org.timezone)}{late && ` · ${t("leads.overdue")}`}
    </span>
  );
}

function LeadSummary({ lead, typeName, assignee }: { lead: Lead; typeName: string | null; assignee: string | null }) {
  const { t } = useTranslation();
  return (
    <div className="grid min-w-0 gap-1 text-sm">
      <div className="flex items-start gap-2">
        <span className="min-w-0 flex-1 truncate font-medium">№{lead.number} · {lead.full_name ?? t("leads.noName")}</span>
        <LeadStatusBadge lead={lead} />
      </div>
      <div className="text-xs text-muted-foreground">{lead.phone ? formatKzPhone(lead.phone) : "—"} · {t(`bookings.source.${lead.source}`)}</div>
      <div className="text-xs text-muted-foreground"><Wishes lead={lead} typeName={typeName} /></div>
      <div className="flex flex-wrap justify-between gap-x-3 text-xs">
        <span>{assignee ?? t("leads.unassigned")}</span>
        <NextContact lead={lead} />
      </div>
    </div>
  );
}

function LeadDetailsDialog({ lead, canWrite, typeName, assignee, onClose, onEdit, onConvert }: {
  lead: Lead;
  canWrite: boolean;
  typeName: string | null;
  assignee: string | null;
  onClose: () => void;
  onEdit: () => void;
  onConvert: () => void;
}) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can } = useOrg();
  const qc = useQueryClient();
  const [note, setNote] = useState("");
  const [losing, setLosing] = useState(false);
  const [reason, setReason] = useState<LeadLostReason>("price");
  const [lostNote, setLostNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [bookingOpen, setBookingOpen] = useState(false);
  const [bookingEdit, setBookingEdit] = useState<Booking | null>(null);
  const leadOpen = isLeadOpen(lead);

  const notes = useQuery({
    queryKey: ["leads", org.id, "notes", lead.id],
    queryFn: async () => {
      const { data, error } = await supabase.from("lead_notes").select("id, body, created_by, created_at").eq("lead_id", lead.id).order("created_at");
      if (error) throw error;
      return data as LeadNote[];
    },
  });
  const staff = useStaff(org.id, "leads.write");
  const types = useRoomTypes(org.id);
  const rooms = useRooms(org.id);
  const booking = useQuery({
    queryKey: ["bookings", org.id, "one", lead.booking_id],
    enabled: Boolean(lead.booking_id) && can("bookings.read"),
    queryFn: async () => {
      const { data, error } = await supabase.from("bookings").select(BOOKING_SELECT).eq("id", lead.booking_id!).maybeSingle();
      if (error) throw error;
      return data as unknown as Booking | null;
    },
  });

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ["leads", org.id] });
    void qc.invalidateQueries({ queryKey: ["lead-counts", org.id] });
  };
  const run = async (fn: () => PromiseLike<{ error: unknown }>, ok?: string) => {
    setBusy(true);
    const { error } = await fn();
    setBusy(false);
    if (error) {
      toast.error(describeLeadError(error, t));
      return false;
    }
    if (ok) toast.success(ok);
    refresh();
    return true;
  };

  const addNote = async () => {
    if (!note.trim()) return;
    if (await run(() => supabase.rpc("add_lead_note", { p_lead_id: lead.id, p_body: note.trim() }))) setNote("");
  };
  const toWork = () => run(() => supabase.rpc("set_lead_status", { p_lead_id: lead.id, p_status: "in_progress" }), t("leads.movedToWork"));
  const markLost = async () => {
    if (await run(() => supabase.rpc("set_lead_status", { p_lead_id: lead.id, p_status: "lost", p_lost_reason: reason, p_note: lostNote.trim() || null }), t("leads.markedLost"))) {
      setLosing(false);
    }
  };
  const author = (id: string | null) => (id ? staff.data?.find((s) => s.user_id === id)?.full_name ?? "—" : t("leads.system"));
  const phone = lead.phone;

  return (
    <>
      <Dialog open onOpenChange={(o) => !o && onClose()} className="max-w-xl" title={t("leads.detailsTitle", { number: lead.number })}>
        <div className="flex flex-wrap items-center gap-2">
          <LeadStatusBadge lead={lead} />
          <span className="text-xs text-muted-foreground">{t(`bookings.source.${lead.source}`)} · {formatDateTime(lead.created_at, lang, org.timezone)}</span>
        </div>

        <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
          <dt className="text-muted-foreground">{t("leads.fields.contact")}</dt>
          <dd className="min-w-0">
            <div className="font-medium">{lead.full_name ?? t("leads.noName")}</div>
            {phone && (
              <span className="flex flex-wrap gap-x-2">
                <a className="text-primary hover:underline" href={`tel:${phone}`}>{formatKzPhone(phone)}</a>
                {can("messages.read") ? (
                  <Link className="text-primary hover:underline" to={`/app/${org.slug}/messages?${new URLSearchParams({ phone })}`}>{t("messages.chat")}</Link>
                ) : (
                  <a className="text-primary hover:underline" href={whatsappLink(phone)} target="_blank" rel="noopener noreferrer">WhatsApp</a>
                )}
              </span>
            )}
            {lead.guest && lead.guest.full_name !== lead.full_name && (
              <div className="text-xs text-muted-foreground">{t("leads.guestCard", { name: lead.guest.full_name })}</div>
            )}
          </dd>
          <dt className="text-muted-foreground">{t("leads.fields.wishes")}</dt>
          <dd><Wishes lead={lead} typeName={typeName} full /></dd>
          {lead.comment && (<><dt className="text-muted-foreground">{t("leads.fields.comment")}</dt><dd className="whitespace-pre-line break-words">{lead.comment}</dd></>)}
          <dt className="text-muted-foreground">{t("leads.fields.assignee")}</dt>
          <dd>{assignee ?? t("leads.unassigned")}</dd>
          <dt className="text-muted-foreground">{t("leads.fields.nextContact")}</dt>
          <dd><NextContact lead={lead} /></dd>
          {lead.status === "lost" && lead.lost_reason && (
            <><dt className="text-muted-foreground">{t("leads.fields.lostReason")}</dt>
              <dd>{t(`leads.lostReason.${lead.lost_reason}`)}{lead.lost_note ? ` · ${lead.lost_note}` : ""}</dd></>
          )}
          {lead.booking_id && (
            <><dt className="text-muted-foreground">{t("leads.fields.booking")}</dt>
              <dd>
                {booking.data ? (
                  <button className="text-primary hover:underline" onClick={() => setBookingOpen(true)}>
                    №{booking.data.number} · {t(`bookings.status.${booking.data.status}`)}
                  </button>
                ) : "—"}
              </dd></>
          )}
        </dl>

        {canWrite && (
          <div className="mt-4 flex flex-wrap gap-2">
            {leadOpen && !lead.booking_id && can("bookings.write") && <Button size="sm" onClick={onConvert}>{t("leads.convert")}</Button>}
            {leadOpen && lead.booking_id && booking.data?.status === "new_request" && (
              <Button size="sm" onClick={() => setBookingOpen(true)}>{t("leads.confirmBooking")}</Button>
            )}
            {(lead.status === "new" || lead.status === "lost") && (
              <Button size="sm" variant="outline" disabled={busy} onClick={toWork}>{t(lead.status === "lost" ? "leads.reopen" : "leads.toWork")}</Button>
            )}
            {leadOpen && <Button size="sm" variant="outline" onClick={onEdit}><Pencil /> {t("common.edit")}</Button>}
            {leadOpen && !losing && <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setLosing(true)}>{t("leads.markLost")}</Button>}
          </div>
        )}
        {losing && (
          <div className="mt-3 grid gap-2 rounded-md border bg-muted/40 p-3">
            <div className="grid gap-2 sm:grid-cols-[180px_1fr]">
              <NativeSelect aria-label={t("leads.fields.lostReason")} value={reason} onChange={(e) => setReason(e.target.value as LeadLostReason)}>
                {LOST_REASONS.map((r) => <option key={r} value={r}>{t(`leads.lostReason.${r}`)}</option>)}
              </NativeSelect>
              <Input placeholder={t("leads.lostNote")} aria-label={t("leads.lostNote")} maxLength={500} value={lostNote} onChange={(e) => setLostNote(e.target.value)} />
            </div>
            <div className="flex justify-end gap-2">
              <Button size="sm" variant="ghost" onClick={() => setLosing(false)}>{t("common.cancel")}</Button>
              <Button size="sm" variant="destructive" disabled={busy} onClick={markLost}>{t("leads.markLost")}</Button>
            </div>
          </div>
        )}

        <section className="mt-5 border-t pt-4">
          <h3 className="text-sm font-semibold">{t("leads.notesTitle")}</h3>
          {notes.data?.length ? (
            <ul className="mt-2 grid gap-2">
              {notes.data.map((n) => (
                <li key={n.id} className="rounded-md bg-muted/50 px-3 py-2 text-sm">
                  <p className="whitespace-pre-line break-words">{n.body}</p>
                  <p className="mt-1 text-xs text-muted-foreground">{author(n.created_by)} · {formatDateTime(n.created_at, lang, org.timezone)}</p>
                </li>
              ))}
            </ul>
          ) : (
            <p className="mt-1 text-sm text-muted-foreground">{t("leads.noNotes")}</p>
          )}
          {canWrite && (
            <div className="mt-2 flex items-end gap-2">
              <Textarea rows={2} maxLength={2000} className="min-h-[44px] flex-1" placeholder={t("leads.notePlaceholder")} aria-label={t("leads.notePlaceholder")}
                value={note} onChange={(e) => setNote(e.target.value)} />
              <Button size="sm" disabled={busy || !note.trim()} onClick={addNote}>{t("leads.addNote")}</Button>
            </div>
          )}
        </section>
      </Dialog>

      {bookingOpen && booking.data && types.data && rooms.data && (
        <BookingDetailsDialog booking={booking.data} rooms={rooms.data} roomTypes={types.data}
          onEdit={() => { setBookingEdit(booking.data!); setBookingOpen(false); }} onClose={() => setBookingOpen(false)} />
      )}
      {bookingEdit && types.data && <BookingDialog booking={bookingEdit} roomTypes={types.data} onClose={() => setBookingEdit(null)} />}
    </>
  );
}

function LeadDialog({ value, staff, roomTypes, onClose, onSaved }: {
  value: Lead | null;
  staff: { user_id: string; full_name: string }[];
  roomTypes: { id: string; name: string; is_active: boolean }[];
  onClose: () => void;
  onSaved: (id: string) => void;
}) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const tz = org.timezone;
  const today = todayInTimeZone(tz);
  const [name, setName] = useState(value?.full_name ?? "");
  const [phone, setPhone] = useState(value?.phone ? formatKzPhone(value.phone) : "");
  const [source, setSource] = useState<BookingSource>(value?.source ?? "phone");
  const [typeId, setTypeId] = useState(value?.room_type_id ?? "");
  const [checkIn, setCheckIn] = useState(value?.check_in ?? "");
  const [checkOut, setCheckOut] = useState(value?.check_out ?? "");
  const [adults, setAdults] = useState(value?.adults ? String(value.adults) : "");
  const [children, setChildren] = useState(value?.children ? String(value.children) : "");
  const [interest, setInterest] = useState(value?.interest ?? "");
  const [comment, setComment] = useState(value?.comment ?? "");
  const [assignee, setAssignee] = useState(value?.assignee_id ?? "");
  const [contactDate, setContactDate] = useState(value?.next_contact_at ? dateInTimeZone(value.next_contact_at, tz) : "");
  const [contactTime, setContactTime] = useState(value?.next_contact_at ? formatTime(value.next_contact_at, "ru", tz) : "");
  const [busy, setBusy] = useState(false);

  const parsedPhone = optionalGuestPhone.safeParse(phone);
  const phoneValue = parsedPhone.success ? parsedPhone.data : null;
  const duplicates = useQuery({
    queryKey: ["leads", org.id, "by-phone", phoneValue],
    enabled: Boolean(phoneValue) && phoneValue !== value?.phone,
    queryFn: async () => {
      const { data, error } = await supabase.from("leads").select("id, number").eq("tenant_id", org.id).eq("phone", phoneValue!)
        .in("status", ["new", "in_progress"]).limit(3);
      if (error) throw error;
      return data as { id: string; number: number }[];
    },
  });

  const save = async () => {
    if (!parsedPhone.success) return toast.error(t("validation.phone"));
    if (!name.trim() && !phoneValue) return toast.error(t("leads.errors.contact"));
    if (checkOut && (!checkIn || checkOut <= checkIn)) return toast.error(t("leads.errors.dates"));
    const args = {
      p_source: source, p_full_name: name.trim() || null, p_phone: phoneValue, p_room_type_id: typeId || null,
      p_check_in: checkIn || null, p_check_out: checkOut || null,
      p_adults: adults ? Number(adults) : null, p_children: children ? Number(children) : null,
      p_interest: interest.trim() || null, p_comment: comment.trim() || null, p_assignee_id: assignee || null,
      p_next_contact_at: contactDate ? zonedDateTime(contactDate, contactTime || "10:00", tz) : null,
    };
    setBusy(true);
    const res = value
      ? await supabase.rpc("update_lead", { p_lead_id: value.id, ...args })
      : await supabase.rpc("create_lead", { p_tenant: org.id, ...args });
    setBusy(false);
    if (res.error) return toast.error(describeLeadError(res.error, t));
    toast.success(t(value ? "common.saved" : "leads.created"));
    void qc.invalidateQueries({ queryKey: ["leads", org.id] });
    void qc.invalidateQueries({ queryKey: ["lead-counts", org.id] });
    onSaved(value?.id ?? (res.data as string));
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} className="max-w-xl"
      title={value ? t("leads.editTitle", { number: value.number }) : t("leads.new")}>
      <div className="grid gap-3">
        <div className="grid gap-3 sm:grid-cols-2">
          <FormField id="lead-name" label={t("leads.fields.name")}>
            <Input id="lead-name" maxLength={200} value={name} onChange={(e) => setName(e.target.value)} autoFocus />
          </FormField>
          <FormField id="lead-phone" label={t("guests.fields.phone")} error={phone && !parsedPhone.success ? t("validation.phone") : undefined}>
            <Input id="lead-phone" type="tel" inputMode="tel" placeholder="+7 7XX XXX XX XX" value={phone} onChange={(e) => setPhone(e.target.value)} />
          </FormField>
        </div>
        {(duplicates.data?.length ?? 0) > 0 && (
          <p className="rounded-md border border-warning/40 bg-warning/5 px-3 py-2 text-xs">
            {t("leads.duplicate", { numbers: duplicates.data!.map((d) => `№${d.number}`).join(", ") })}
          </p>
        )}
        <div className="grid grid-cols-2 gap-3">
          <FormField id="lead-source" label={t("leads.fields.source")}>
            <NativeSelect id="lead-source" value={source} onChange={(e) => setSource(e.target.value as BookingSource)}>
              {BOOKING_SOURCES.map((s) => <option key={s} value={s}>{t(`bookings.source.${s}`)}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="lead-type" label={t("bookings.fields.roomType")}>
            <NativeSelect id="lead-type" value={typeId} onChange={(e) => setTypeId(e.target.value)}>
              <option value="">—</option>
              {roomTypes.filter((x) => x.is_active || x.id === typeId).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="lead-in" label={t("bookings.fields.checkIn")}>
            <Input id="lead-in" type="date" min={value ? undefined : today} value={checkIn} onChange={(e) => setCheckIn(e.target.value)} />
          </FormField>
          <FormField id="lead-out" label={t("bookings.fields.checkOut")}>
            <Input id="lead-out" type="date" min={checkIn || undefined} value={checkOut} onChange={(e) => setCheckOut(e.target.value)} />
          </FormField>
          <FormField id="lead-adults" label={t("bookings.fields.adults")}>
            <Input id="lead-adults" type="number" min={1} max={50} value={adults} onChange={(e) => setAdults(e.target.value)} />
          </FormField>
          <FormField id="lead-children" label={t("bookings.fields.children")}>
            <Input id="lead-children" type="number" min={0} max={50} value={children} onChange={(e) => setChildren(e.target.value)} />
          </FormField>
        </div>
        <FormField id="lead-interest" label={t("leads.fields.interest")}>
          <Input id="lead-interest" maxLength={500} placeholder={t("leads.interestPlaceholder")} value={interest} onChange={(e) => setInterest(e.target.value)} />
        </FormField>
        <FormField id="lead-comment" label={t("leads.fields.comment")}>
          <Textarea id="lead-comment" rows={2} maxLength={2000} value={comment} onChange={(e) => setComment(e.target.value)} />
        </FormField>
        <div className="grid gap-3 sm:grid-cols-3">
          <FormField id="lead-assignee" label={t("leads.fields.assignee")}>
            <NativeSelect id="lead-assignee" value={assignee} onChange={(e) => setAssignee(e.target.value)}>
              <option value="">{t("leads.unassigned")}</option>
              {staff.map((s) => <option key={s.user_id} value={s.user_id}>{s.full_name}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="lead-contact" label={t("leads.fields.nextContact")}>
            <Input id="lead-contact" type="date" value={contactDate} onChange={(e) => setContactDate(e.target.value)} />
          </FormField>
          <FormField id="lead-contact-time" label={t("leads.fields.time")}>
            <Input id="lead-contact-time" type="time" step={300} value={contactTime} disabled={!contactDate} onChange={(e) => setContactTime(e.target.value)} />
          </FormField>
        </div>
        {contactDate && <p className="-mt-1 text-xs text-muted-foreground">{formatDate(contactDate, lang)} {contactTime || "10:00"}</p>}
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy} onClick={save}>{busy ? t("common.saving") : t("common.save")}</Button>
      </DialogFooter>
    </Dialog>
  );
}

/** Ссылка на открытую заявку по номеру телефона (для переписки WhatsApp) */
export function useOpenLeadByPhone(tenantId: string, phone: string | null, enabled: boolean) {
  return useQuery({
    queryKey: ["leads", tenantId, "open-by-phone", phone],
    enabled: enabled && Boolean(phone),
    queryFn: async () => {
      const { data, error } = await supabase.from("leads").select("id, number").eq("tenant_id", tenantId).eq("phone", phone!)
        .in("status", ["new", "in_progress"]).order("created_at", { ascending: false }).limit(1);
      if (error) throw error;
      return (data as { id: string; number: number }[])[0] ?? null;
    },
  });
}
