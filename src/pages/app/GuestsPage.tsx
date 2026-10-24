import { useDeferredValue, useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Pencil, Plus, Search, UserRound } from "lucide-react";
import { toast } from "sonner";
import type { z } from "zod";
import { supabase } from "@/lib/supabase";
import { guestSchema } from "@/lib/schemas";
import { formatDate, formatKzPhone, formatKzt, type AppLanguage } from "@/lib/format";
import { bookingStatusVariant, describeBookingError, type Booking, type Guest } from "@/lib/bookings";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, Textarea } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";

type GuestInput = z.input<typeof guestSchema>;
type GuestOutput = z.output<typeof guestSchema>;

/** Поиск по имени, телефону или email. Символы, значимые для фильтра PostgREST, убираются. */
export function guestSearchFilter(term: string): string | null {
  const clean = term.replace(/[,()%*\\]/g, " ").trim();
  if (clean.length < 2) return null;
  const digits = clean.replace(/\D/g, "");
  const parts = [`full_name.ilike.%${clean}%`, `email.ilike.%${clean}%`];
  // в Казахстане номер часто набирают с 8: «8 701…» ищем как «7701…»
  if (digits.length >= 3) parts.push(`phone.like.%${/^87\d/.test(digits) ? `7${digits.slice(1)}` : digits}%`);
  return parts.join(",");
}

export function useGuestSearch(tenantId: string, term: string, enabled = true) {
  return useQuery({
    queryKey: ["guests", tenantId, term],
    enabled,
    queryFn: async () => {
      let q = supabase.from("guests").select("*").eq("tenant_id", tenantId).is("archived_at", null)
        .order("created_at", { ascending: false }).limit(50);
      const filter = guestSearchFilter(term);
      if (filter) q = q.or(filter);
      const { data, error } = await q;
      if (error) throw error;
      return data as Guest[];
    },
  });
}

/** Гости санатория: поиск, карточка, история проживаний */
export function GuestsPage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable } = useOrg();
  const qc = useQueryClient();
  const canWrite = can("guests.write") && writable;
  const [term, setTerm] = useState("");
  const deferred = useDeferredValue(term);
  const guests = useGuestSearch(org.id, deferred);
  const [editing, setEditing] = useState<Guest | "new" | null>(null);
  const [viewing, setViewing] = useState<Guest | null>(null);

  return (
    <>
      <PageHeader
        title={t("guests.title")}
        description={t("guests.subtitle")}
        actions={canWrite && <Button onClick={() => setEditing("new")}><Plus /> {t("guests.add")}</Button>}
      />
      <div className="relative mb-4 max-w-md">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input className="pl-9" placeholder={t("guests.search")} value={term} onChange={(e) => setTerm(e.target.value)} aria-label={t("guests.search")} />
      </div>

      {guests.isLoading ? (
        <div className="grid gap-2">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-12" />)}</div>
      ) : guests.error ? (
        <ErrorState error={guests.error} onRetry={() => guests.refetch()} />
      ) : guests.data!.length === 0 ? (
        <EmptyState icon={<UserRound className="h-5 w-5" />} title={term ? t("guests.notFound") : t("guests.empty")}
          text={term ? undefined : t("guests.emptyText")} />
      ) : (
        <Card>
          <CardContent className="pt-5">
            <div className="-mx-5 overflow-x-auto">
              <table className="w-full min-w-[560px] text-sm">
                <thead>
                  <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
                    <th className="px-5 py-2 font-medium">{t("guests.colName")}</th>
                    <th className="px-5 py-2 font-medium">{t("guests.colPhone")}</th>
                    <th className="px-5 py-2 font-medium">{t("guests.colCity")}</th>
                    <th className="px-5 py-2 font-medium">{t("guests.colCreated")}</th>
                    <th className="px-5 py-2" />
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {guests.data!.map((g) => (
                    <tr key={g.id} className="cursor-pointer hover:bg-muted/50" onClick={() => setViewing(g)}>
                      <td className="px-5 py-2.5 font-medium">{g.full_name}</td>
                      <td className="whitespace-nowrap px-5 py-2.5">{g.phone ? formatKzPhone(g.phone) : "—"}</td>
                      <td className="px-5 py-2.5">{g.city ?? "—"}</td>
                      <td className="px-5 py-2.5">{formatDate(g.created_at, lang)}</td>
                      <td className="px-5 py-2.5 text-right">
                        {canWrite && (
                          <Button size="icon" variant="ghost" aria-label={t("common.edit")}
                            onClick={(e) => { e.stopPropagation(); setEditing(g); }}><Pencil /></Button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {guests.data!.length === 50 && <p className="mt-3 text-xs text-muted-foreground">{t("guests.limitNote")}</p>}
          </CardContent>
        </Card>
      )}

      {editing && (
        <GuestDialog
          value={editing === "new" ? null : editing}
          onClose={() => setEditing(null)}
          onSaved={() => void qc.invalidateQueries({ queryKey: ["guests", org.id] })}
        />
      )}
      {viewing && <GuestHistoryDialog guest={viewing} onClose={() => setViewing(null)} />}
    </>
  );
}

/** Создание и изменение гостя. Используется также в форме брони. */
export function GuestDialog({ value, initialName, onClose, onSaved }: {
  value: Guest | null;
  initialName?: string;
  onClose: () => void;
  onSaved: (guest: Guest) => void;
}) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const form = useForm<GuestInput, unknown, GuestOutput>({
    resolver: zodResolver(guestSchema),
    defaultValues: {
      full_name: value?.full_name ?? initialName ?? "",
      phone: value?.phone ?? "",
      email: value?.email ?? "",
      birth_date: value?.birth_date ?? "",
      city: value?.city ?? "",
      notes: value?.notes ?? "",
    },
  });
  const e = form.formState.errors;
  const err = (m?: string) => (m ? t(m) : undefined);

  const onSubmit = form.handleSubmit(async (v) => {
    const { data, error } = value
      ? await supabase.from("guests").update(v).eq("id", value.id).select().single()
      : await supabase.from("guests").insert({ ...v, tenant_id: org.id }).select().single();
    if (error) { toast.error(describeBookingError(error, t)); return; }
    toast.success(t("common.saved"));
    onSaved(data as Guest);
    onClose();
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={value ? t("guests.edit") : t("guests.add")}>
      <form onSubmit={onSubmit} className="grid gap-3" noValidate>
        <FormField id="guest-name" label={t("guests.fields.fullName")} error={err(e.full_name?.message)}>
          <Input id="guest-name" autoComplete="off" {...form.register("full_name")} />
        </FormField>
        <div className="grid gap-3 sm:grid-cols-2">
          <FormField id="guest-phone" label={t("guests.fields.phone")} error={err(e.phone?.message)} hint={t("guests.fields.phoneHint")}>
            <Input id="guest-phone" type="tel" placeholder="+7 701 123 45 67" {...form.register("phone")} />
          </FormField>
          <FormField id="guest-email" label={`Email (${t("common.optional")})`} error={err(e.email?.message)}>
            <Input id="guest-email" type="email" {...form.register("email")} />
          </FormField>
          <FormField id="guest-birth" label={`${t("guests.fields.birthDate")} (${t("common.optional")})`}>
            <Input id="guest-birth" type="date" {...form.register("birth_date")} />
          </FormField>
          <FormField id="guest-city" label={`${t("guests.fields.city")} (${t("common.optional")})`}>
            <Input id="guest-city" {...form.register("city")} />
          </FormField>
        </div>
        <FormField id="guest-notes" label={`${t("guests.fields.notes")} (${t("common.optional")})`} hint={t("guests.fields.notesHint")}>
          <Textarea id="guest-notes" rows={2} {...form.register("notes")} />
        </FormField>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={form.formState.isSubmitting}>{form.formState.isSubmitting ? t("common.saving") : t("common.save")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}

function GuestHistoryDialog({ guest, onClose }: { guest: Guest; onClose: () => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { can } = useOrg();
  const history = useQuery({
    queryKey: ["guest-bookings", guest.id],
    enabled: can("bookings.read"),
    queryFn: async () => {
      const { data, error } = await supabase.from("bookings")
        .select("id, number, check_in, check_out, nights, status, total_amount")
        .eq("guest_id", guest.id).order("check_in", { ascending: false });
      if (error) throw error;
      return data as Pick<Booking, "id" | "number" | "check_in" | "check_out" | "nights" | "status" | "total_amount">[];
    },
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={guest.full_name} description={[guest.phone && formatKzPhone(guest.phone), guest.email, guest.city].filter(Boolean).join(" · ") || undefined}>
      {guest.birth_date && <p className="text-sm">{t("guests.fields.birthDate")}: {formatDate(guest.birth_date, lang)}</p>}
      {guest.notes && <p className="mt-2 whitespace-pre-line rounded-md bg-muted p-3 text-sm">{guest.notes}</p>}
      {can("bookings.read") && (
        <>
          <h3 className="mt-4 text-sm font-semibold">{t("guests.history")}</h3>
          {history.isLoading ? <Skeleton className="mt-2 h-12" /> : history.error ? (
            <ErrorState error={history.error} onRetry={() => history.refetch()} />
          ) : history.data!.length === 0 ? (
            <p className="mt-2 text-sm text-muted-foreground">{t("guests.noHistory")}</p>
          ) : (
            <ul className="mt-2 divide-y rounded-md border text-sm">
              {history.data!.map((b) => (
                <li key={b.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2">
                  <span className="font-medium">№{b.number}</span>
                  <span>{formatDate(b.check_in, lang)} — {formatDate(b.check_out, lang)}</span>
                  <Badge variant={bookingStatusVariant[b.status]}>{t(`bookings.status.${b.status}`)}</Badge>
                  <span className="ml-auto">{formatKzt(b.total_amount, lang)}</span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </Dialog>
  );
}
