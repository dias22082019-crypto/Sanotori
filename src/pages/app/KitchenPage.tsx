import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ChevronLeft, ChevronRight, Copy, Pencil, Plus, UtensilsCrossed } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { formatDate, todayInTimeZone, type AppLanguage } from "@/lib/format";
import { addDays } from "@/lib/bookings";
import {
  DIET_SELECT, MEALS, describeKitchenError, portionGrid, sortDiets,
  type BookingDiet, type DietType, type KitchenDay, type KitchenGuest, type Meal,
} from "@/lib/kitchen";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
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

const TABS = ["day", "diets"] as const;
type Tab = (typeof TABS)[number];

export function useDiets(tenantId: string, enabled = true) {
  return useQuery({
    queryKey: ["diet-types", tenantId],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.from("diet_types").select(DIET_SELECT).eq("tenant_id", tenantId);
      if (error) throw error;
      return sortDiets(data as DietType[]);
    },
  });
}

function invalidateKitchen(qc: ReturnType<typeof useQueryClient>, tenantId: string) {
  for (const key of ["kitchen-day", "diet-types", "booking-diet"]) void qc.invalidateQueries({ queryKey: [key, tenantId] });
}

/** Питание: порции на день по столам, меню, столы гостей; справочник столов */
export function KitchenPage() {
  const { t } = useTranslation();
  const { org, hasFeature } = useOrg();
  const [params, setParams] = useSearchParams();
  const tab: Tab = params.get("tab") === "diets" ? "diets" : "day";
  const today = todayInTimeZone(org.timezone);
  const date = /^\d{4}-\d{2}-\d{2}$/.test(params.get("date") ?? "") ? params.get("date")! : today;

  return (
    <>
      <PageHeader title={t("kitchen.title")} description={t("kitchen.subtitle")} />
      {!hasFeature("kitchen") && (
        <Card className="mb-4 border-warning/40 bg-warning/5">
          <CardContent className="py-3 text-sm">{t("kitchen.planNote")}</CardContent>
        </Card>
      )}
      <div className="-mx-4 mb-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
        <div role="tablist" className="inline-flex gap-1 rounded-lg bg-muted p-1">
          {TABS.map((key) => (
            <button key={key} role="tab" aria-selected={tab === key}
              className={cn("whitespace-nowrap rounded-md px-3 py-1.5 text-sm", tab === key ? "bg-card font-medium shadow-sm" : "text-muted-foreground hover:text-foreground")}
              onClick={() => setParams({ tab: key, date }, { replace: true })}>
              {t(`kitchen.tabs.${key}`)}
            </button>
          ))}
        </div>
      </div>
      {tab === "diets" ? <DietCatalog /> : <KitchenDayView date={date} today={today} onDate={(d) => setParams({ tab, date: d }, { replace: true })} />}
    </>
  );
}

function StandardDietsButton({ variant = "default" }: { variant?: "default" | "outline" }) {
  const { t, i18n } = useTranslation();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const add = async () => {
    setBusy(true);
    const { data, error } = await supabase.rpc("add_standard_diets", { p_tenant: org.id, p_lang: i18n.language === "kk" ? "kk" : "ru" });
    setBusy(false);
    if (error) return toast.error(describeKitchenError(error, t));
    toast.success(t("kitchen.standardAdded", { count: data as number }));
    invalidateKitchen(qc, org.id);
  };
  return <Button variant={variant} disabled={busy} onClick={add}><Plus /> {t("kitchen.addStandard")}</Button>;
}

function KitchenDayView({ date, today, onDate }: { date: string; today: string; onDate: (d: string) => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable, hasFeature } = useOrg();
  const diets = useDiets(org.id);
  const day = useQuery({
    queryKey: ["kitchen-day", org.id, date],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("kitchen_day", { p_tenant: org.id, p_date: date });
      if (error) throw error;
      return data as KitchenDay;
    },
  });
  const [menuOpen, setMenuOpen] = useState(false);
  const [copyOpen, setCopyOpen] = useState(false);
  const [dietFor, setDietFor] = useState<KitchenGuest | null>(null);

  const canStandard = can("kitchen.write") && writable && hasFeature("kitchen");
  if (diets.isLoading || day.isLoading) return <Skeleton className="h-64" />;
  if (diets.error) return <ErrorState error={diets.error} onRetry={() => diets.refetch()} />;
  if (day.error) return <ErrorState error={day.error} onRetry={() => day.refetch()} />;

  const list = diets.data!;
  const d = day.data!;
  const dietById = new Map(list.map((x) => [x.id, x]));
  const label = (id: string | null) => (id && dietById.get(id) ? `№${dietById.get(id)!.code}` : t("kitchen.noDiet"));
  const { rows, totals } = portionGrid(d, list);
  const menuFor = (meal: Meal) => d.menus.filter((m) => m.meal === meal)
    .sort((a, b) => list.findIndex((x) => x.id === a.diet_type_id) - list.findIndex((x) => x.id === b.diet_type_id));

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <div className="flex items-center gap-1">
          <Button variant="outline" size="icon" aria-label={t("kitchen.prevDay")} onClick={() => onDate(addDays(date, -1))}><ChevronLeft /></Button>
          <Input type="date" className="w-40" value={date} aria-label={t("kitchen.date")} onChange={(e) => e.target.value && onDate(e.target.value)} />
          <Button variant="outline" size="icon" aria-label={t("kitchen.nextDay")} onClick={() => onDate(addDays(date, 1))}><ChevronRight /></Button>
        </div>
        {date !== today && <Button variant="ghost" size="sm" onClick={() => onDate(today)}>{t("kitchen.today")}</Button>}
        {d.can_write && list.length > 0 && (
          <div className="ml-auto flex flex-wrap gap-2">
            <Button variant="outline" onClick={() => setCopyOpen(true)}><Copy /> {t("kitchen.copyMenu")}</Button>
            <Button onClick={() => setMenuOpen(true)}><Pencil /> {t("kitchen.editMenu")}</Button>
          </div>
        )}
      </div>

      {list.length === 0 && (
        <EmptyState icon={<UtensilsCrossed />} title={t("kitchen.noDietsTitle")} text={t("kitchen.noDietsText")}
          action={canStandard ? <StandardDietsButton /> : undefined} />
      )}

      <div className="grid gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
        <Card className="min-w-0">
          <CardHeader><CardTitle className="text-base">{t("kitchen.portions", { date: formatDate(date, lang) })}</CardTitle></CardHeader>
          <CardContent>
            {rows.length === 0 ? <p className="text-sm text-muted-foreground">{t("kitchen.nobodyEats")}</p> : (
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-xs text-muted-foreground">
                    <th className="py-2 pr-2 font-medium">{t("kitchen.diet")}</th>
                    {MEALS.map((m) => <th key={m} className="px-1 py-2 text-right font-medium">{t(`kitchen.meals.${m}`)}</th>)}
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.dietId ?? "none"} className="border-b last:border-0">
                      <td className="py-2 pr-2">
                        <span className="font-medium">{label(r.dietId)}</span>
                        {r.dietId && dietById.get(r.dietId) && <span className="ml-1.5 text-xs text-muted-foreground">{dietById.get(r.dietId)!.name}</span>}
                      </td>
                      {MEALS.map((m) => <td key={m} className="px-1 py-2 text-right tabular-nums">{r.counts[m] || "—"}</td>)}
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr className="font-semibold">
                    <td className="pt-2">{t("kitchen.total")}</td>
                    {MEALS.map((m) => <td key={m} className="px-1 pt-2 text-right tabular-nums">{totals[m]}</td>)}
                  </tr>
                </tfoot>
              </table>
            )}
            <p className="mt-3 text-xs text-muted-foreground">{t("kitchen.portionsHint")}</p>
          </CardContent>
        </Card>

        <Card className="min-w-0">
          <CardHeader><CardTitle className="text-base">{t("kitchen.menu")}</CardTitle></CardHeader>
          <CardContent>
            {d.menus.length === 0 ? <p className="text-sm text-muted-foreground">{t("kitchen.noMenu")}</p> : (
              <div className="space-y-4">
                {MEALS.filter((m) => menuFor(m).length > 0).map((m) => (
                  <section key={m}>
                    <h3 className="mb-1 text-sm font-semibold">{t(`kitchen.meals.${m}`)}</h3>
                    <dl className="space-y-1 text-sm">
                      {menuFor(m).map((x) => (
                        <div key={x.diet_type_id} className="grid grid-cols-[3.5rem_minmax(0,1fr)] gap-2">
                          <dt className="font-medium">{label(x.diet_type_id)}</dt>
                          <dd className="whitespace-pre-line break-words">{x.dishes}</dd>
                        </div>
                      ))}
                    </dl>
                  </section>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader><CardTitle className="text-base">{t("kitchen.guests")} · {d.guests.length}</CardTitle></CardHeader>
        <CardContent className="p-0">
          {d.guests.length === 0 ? <p className="px-6 pb-6 text-sm text-muted-foreground">{t("kitchen.nobodyEats")}</p> : (
            <ul className="divide-y">
              {d.guests.map((g) => {
                const diet = g.diet_type_id ? dietById.get(g.diet_type_id) : undefined;
                return (
                  <li key={g.booking_id} className="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-3 text-sm sm:px-6">
                    <span className="w-12 shrink-0 font-medium tabular-nums">{g.room ? `№${g.room}` : "—"}</span>
                    <span className="min-w-[10rem] flex-1">
                      <span className="font-medium">{g.full_name}</span>
                      {g.persons > 1 && <span className="ml-1.5 text-muted-foreground">+{g.persons - 1}</span>}
                      {g.kitchen_note && <span className="block text-xs text-muted-foreground">{g.kitchen_note}</span>}
                    </span>
                    <span className="flex w-full flex-wrap items-center gap-1 pl-[3.75rem] sm:w-auto sm:pl-0">
                      {g.meals.length < 3 && g.meals.map((m) => <Badge key={m} variant="outline" className="whitespace-nowrap font-normal">{t(`kitchen.meals.${m}`)}</Badge>)}
                      <Badge variant={diet ? "default" : "secondary"} className="whitespace-nowrap">{diet ? `№${diet.code}` : t("kitchen.defaultDiet")}</Badge>
                      {d.can_set_diet && (
                        <Button variant="ghost" size="sm" className="h-7" onClick={() => setDietFor(g)}><Pencil /> {t("kitchen.setDiet")}</Button>
                      )}
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </CardContent>
      </Card>

      {menuOpen && <MenuDialog date={date} diets={list.filter((x) => x.is_active)} day={d} onClose={() => setMenuOpen(false)} />}
      {copyOpen && <CopyMenuDialog date={date} onClose={() => setCopyOpen(false)} />}
      {dietFor && (
        <DietDialog bookingId={dietFor.booking_id} title={dietFor.full_name} current={{ diet_type_id: dietFor.diet_type_id, kitchen_note: dietFor.kitchen_note }}
          diets={list} onClose={() => setDietFor(null)} />
      )}
    </div>
  );
}

function MenuDialog({ date, diets, day, onClose }: { date: string; diets: DietType[]; day: KitchenDay; onClose: () => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const initial = (meal: Meal, diet: string) => day.menus.find((m) => m.meal === meal && m.diet_type_id === diet)?.dishes ?? "";
  const [meal, setMeal] = useState<Meal>("breakfast");
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(MEALS.flatMap((m) => diets.map((x) => [`${m}:${x.id}`, initial(m, x.id)]))));
  const [busy, setBusy] = useState(false);

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    const changed = MEALS.flatMap((m) => diets.map((x) => ({ m, x, v: values[`${m}:${x.id}`] ?? "" })))
      .filter(({ m, x, v }) => v.trim() !== initial(m, x.id).trim());
    setBusy(true);
    for (const { m, x, v } of changed) {
      const { error } = await supabase.rpc("set_diet_menu", { p_tenant: org.id, p_date: date, p_meal: m, p_diet_type_id: x.id, p_dishes: v });
      if (error) {
        setBusy(false);
        invalidateKitchen(qc, org.id);
        return toast.error(describeKitchenError(error, t));
      }
    }
    setBusy(false);
    if (changed.length) toast.success(t("common.saved"));
    invalidateKitchen(qc, org.id);
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("kitchen.menuTitle", { date: formatDate(date, lang) })} className="sm:max-w-2xl">
      <form onSubmit={save} className="space-y-3">
        <div role="tablist" className="inline-flex gap-1 rounded-lg bg-muted p-1">
          {MEALS.map((m) => (
            <button key={m} type="button" role="tab" aria-selected={meal === m}
              className={cn("whitespace-nowrap rounded-md px-3 py-1.5 text-sm", meal === m ? "bg-card font-medium shadow-sm" : "text-muted-foreground")}
              onClick={() => setMeal(m)}>{t(`kitchen.meals.${m}`)}</button>
          ))}
        </div>
        {diets.map((x) => (
          <FormField key={x.id} id={`menu-${x.id}`} label={`№${x.code} · ${x.name}`}>
            <Textarea id={`menu-${x.id}`} rows={2} maxLength={1000} placeholder={t("kitchen.dishesPlaceholder")}
              value={values[`${meal}:${x.id}`] ?? ""} onChange={(e) => setValues({ ...values, [`${meal}:${x.id}`]: e.target.value })} />
          </FormField>
        ))}
        <p className="text-xs text-muted-foreground">{t("kitchen.menuHint")}</p>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={busy}>{busy ? t("common.saving") : t("common.save")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}

function CopyMenuDialog({ date, onClose }: { date: string; onClose: () => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const [from, setFrom] = useState(addDays(date, -7));
  const [busy, setBusy] = useState(false);
  const copy = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    const { error } = await supabase.rpc("copy_diet_menu", { p_tenant: org.id, p_from: from, p_to: date });
    setBusy(false);
    if (error) return toast.error(describeKitchenError(error, t));
    toast.success(t("kitchen.copied"));
    invalidateKitchen(qc, org.id);
    onClose();
  };
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("kitchen.copyTitle", { date: formatDate(date, lang) })}
      description={t("kitchen.copyHint")}>
      <form onSubmit={copy} className="space-y-3">
        <FormField id="copy-from" label={t("kitchen.copyFrom")}>
          <Input id="copy-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
        </FormField>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={busy || !from || from === date}>{t("kitchen.copy")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}

/** Стол гостя на проживание. Назначают врач (medical.write) или кухня (kitchen.write); проверяет сервер. */
export function DietDialog({ bookingId, title, current, diets, onClose }: {
  bookingId: string; title: string; current: { diet_type_id: string | null; kitchen_note: string | null };
  diets: DietType[]; onClose: () => void;
}) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [dietId, setDietId] = useState(current.diet_type_id ?? "");
  const [note, setNote] = useState(current.kitchen_note ?? "");
  const [busy, setBusy] = useState(false);
  const fallback = diets.find((x) => x.is_default);
  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    const { error } = await supabase.rpc("set_booking_diet", { p_booking_id: bookingId, p_diet_type_id: dietId || null, p_kitchen_note: note || null });
    setBusy(false);
    if (error) return toast.error(describeKitchenError(error, t));
    toast.success(t("common.saved"));
    invalidateKitchen(qc, org.id);
    onClose();
  };
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("kitchen.dietFor", { name: title })}>
      <form onSubmit={save} className="space-y-3">
        <FormField id="diet-type" label={t("kitchen.diet")}>
          <NativeSelect id="diet-type" value={dietId} onChange={(e) => setDietId(e.target.value)}>
            <option value="">{fallback ? t("kitchen.byDefault", { code: fallback.code }) : t("kitchen.noDiet")}</option>
            {diets.filter((x) => x.is_active || x.id === dietId).map((x) => <option key={x.id} value={x.id}>№{x.code} · {x.name}</option>)}
          </NativeSelect>
        </FormField>
        <FormField id="diet-note" label={t("kitchen.kitchenNote")} hint={t("kitchen.kitchenNoteHint")}>
          <Input id="diet-note" maxLength={300} value={note} onChange={(e) => setNote(e.target.value)} />
        </FormField>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={busy}>{busy ? t("common.saving") : t("common.save")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}

/** Стол гостя в медкарте (текущее проживание) */
export function StayDietCard({ bookingId, guestName }: { bookingId: string; guestName: string }) {
  const { t } = useTranslation();
  const { org, hasFeature } = useOrg();
  const [open, setOpen] = useState(false);
  const info = useQuery({
    queryKey: ["booking-diet", org.id, bookingId],
    enabled: hasFeature("kitchen"),
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("booking_diet", { p_booking_id: bookingId });
      if (error) throw error;
      return data as BookingDiet;
    },
  });
  const diets = useDiets(org.id, open);
  if (!hasFeature("kitchen") || info.error || !info.data) return null;
  const b = info.data;
  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between gap-2 space-y-0">
        <CardTitle className="text-base">{t("kitchen.dietCard")}</CardTitle>
        {b.can_set && <Button variant="ghost" size="sm" onClick={() => setOpen(true)}><Pencil /> {t("common.edit")}</Button>}
      </CardHeader>
      <CardContent className="text-sm">
        {b.diet ? (
          <>
            <p className="font-medium">№{b.diet.code} · {b.diet.name}</p>
            {b.diet.kitchen_note && <p className="mt-1 text-muted-foreground">{b.diet.kitchen_note}</p>}
          </>
        ) : (
          <p className="text-muted-foreground">{b.default ? t("kitchen.byDefault", { code: b.default.code }) : t("kitchen.noDiet")}</p>
        )}
        {open && diets.data && (
          <DietDialog bookingId={bookingId} title={guestName}
            current={{ diet_type_id: b.diet?.diet_type_id ?? null, kitchen_note: b.diet?.kitchen_note ?? null }}
            diets={diets.data} onClose={() => setOpen(false)} />
        )}
      </CardContent>
    </Card>
  );
}

function DietCatalog() {
  const { t } = useTranslation();
  const { org, can, writable, hasFeature } = useOrg();
  const diets = useDiets(org.id);
  const [editing, setEditing] = useState<DietType | "new" | null>(null);
  const canWrite = can("kitchen.write") && writable && hasFeature("kitchen");

  if (diets.isLoading) return <Skeleton className="h-48" />;
  if (diets.error) return <ErrorState error={diets.error} onRetry={() => diets.refetch()} />;
  const list = diets.data!;
  return (
    <div className="space-y-4">
      {canWrite && (
        <div className="flex flex-wrap gap-2">
          <Button onClick={() => setEditing("new")}><Plus /> {t("kitchen.newDiet")}</Button>
          <StandardDietsButton variant="outline" />
        </div>
      )}
      {list.length === 0 ? (
        <EmptyState icon={<UtensilsCrossed />} title={t("kitchen.noDietsTitle")} text={t("kitchen.noDietsText")} />
      ) : (
        <Card>
          <ul className="divide-y">
            {list.map((x) => (
              <li key={x.id} className={cn("flex flex-wrap items-center gap-x-3 gap-y-1 px-4 py-3 text-sm sm:px-6", !x.is_active && "text-muted-foreground")}>
                <span className="w-12 shrink-0 font-semibold">№{x.code}</span>
                <span className="min-w-0 flex-1">
                  <span className="font-medium">{x.name}</span>
                  {x.description && <span className="block text-xs text-muted-foreground">{x.description}</span>}
                </span>
                {x.is_default && <Badge variant="success">{t("kitchen.default")}</Badge>}
                {!x.is_active && <Badge variant="secondary">{t("kitchen.inactive")}</Badge>}
                {canWrite && <Button variant="ghost" size="sm" className="h-7" onClick={() => setEditing(x)}><Pencil /> {t("common.edit")}</Button>}
              </li>
            ))}
          </ul>
        </Card>
      )}
      {editing && <DietTypeDialog diet={editing === "new" ? null : editing} onClose={() => setEditing(null)} />}
    </div>
  );
}

function DietTypeDialog({ diet, onClose }: { diet: DietType | null; onClose: () => void }) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [code, setCode] = useState(diet?.code ?? "");
  const [name, setName] = useState(diet?.name ?? "");
  const [description, setDescription] = useState(diet?.description ?? "");
  const [isDefault, setIsDefault] = useState(diet?.is_default ?? false);
  const [isActive, setIsActive] = useState(diet?.is_active ?? true);
  const [busy, setBusy] = useState(false);
  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!code.trim() || !name.trim()) return toast.error(t("kitchen.errors.codeName"));
    setBusy(true);
    const { error } = await supabase.rpc("save_diet_type", {
      p_tenant: org.id, p_id: diet?.id ?? null, p_code: code, p_name: name, p_description: description || null,
      p_is_default: isDefault, p_is_active: isActive, p_sort: diet?.sort ?? 100,
    });
    setBusy(false);
    if (error) return toast.error(describeKitchenError(error, t));
    toast.success(t("common.saved"));
    invalidateKitchen(qc, org.id);
    onClose();
  };
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t(diet ? "kitchen.editDiet" : "kitchen.newDiet")}>
      <form onSubmit={save} className="space-y-3">
        <div className="grid grid-cols-[6rem_minmax(0,1fr)] gap-3">
          <FormField id="diet-code" label={t("kitchen.code")}>
            <Input id="diet-code" maxLength={10} value={code} onChange={(e) => setCode(e.target.value)} placeholder="5" />
          </FormField>
          <FormField id="diet-name" label={t("kitchen.name")}>
            <Input id="diet-name" maxLength={120} value={name} onChange={(e) => setName(e.target.value)} />
          </FormField>
        </div>
        <FormField id="diet-desc" label={t("kitchen.description")}>
          <Textarea id="diet-desc" rows={3} maxLength={1000} value={description} onChange={(e) => setDescription(e.target.value)} />
        </FormField>
        <div className="flex items-center gap-2">
          <Checkbox id="diet-default" checked={isDefault} onCheckedChange={(v) => setIsDefault(v === true)} />
          <Label htmlFor="diet-default" className="font-normal">{t("kitchen.makeDefault")}</Label>
        </div>
        <div className="flex items-center gap-2">
          <Checkbox id="diet-active" checked={isActive} onCheckedChange={(v) => setIsActive(v === true)} />
          <Label htmlFor="diet-active" className="font-normal">{t("kitchen.active")}</Label>
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={busy}>{busy ? t("common.saving") : t("common.save")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
