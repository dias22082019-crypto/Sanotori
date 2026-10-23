import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { BedDouble, CalendarDays, Pencil, Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { z } from "zod";
import { supabase } from "@/lib/supabase";
import { formatDate, formatKzt, type AppLanguage } from "@/lib/format";
import {
  ROOM_STATUSES, describeBookingError, roomStatusVariant,
  type Room, type RoomRate, type RoomStatus, type RoomType,
} from "@/lib/bookings";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect, Textarea } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { ConfirmDialog } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";

export function useRoomTypes(tenantId: string) {
  return useQuery({
    queryKey: ["room-types", tenantId],
    queryFn: async () => {
      const { data, error } = await supabase.from("room_types").select("*").eq("tenant_id", tenantId)
        .order("sort_order").order("name");
      if (error) throw error;
      return data as RoomType[];
    },
  });
}

export function useRooms(tenantId: string) {
  return useQuery({
    queryKey: ["rooms", tenantId],
    queryFn: async () => {
      const { data, error } = await supabase.from("rooms").select("*").eq("tenant_id", tenantId).order("number");
      if (error) throw error;
      // номера сортируются «по-человечески»: 2, 10, 101
      return (data as Room[]).sort((a, b) => a.number.localeCompare(b.number, undefined, { numeric: true }));
    },
  });
}

const money = z.coerce.number({ invalid_type_error: "validation.number" }).min(0, "validation.number").max(100_000_000, "validation.number");
const count = z.coerce.number({ invalid_type_error: "validation.number" }).int("validation.number").min(1, "validation.number").max(30, "validation.number");

const roomTypeSchema = z.object({
  name: z.string().trim().min(1, "validation.required").max(120),
  description: z.string().max(2000).optional(),
  base_occupancy: count,
  max_occupancy: count,
  base_price: money,
  extra_guest_price: money,
  is_public: z.boolean(),
  is_active: z.boolean(),
}).refine((v) => v.max_occupancy >= v.base_occupancy, { path: ["max_occupancy"], message: "rooms.errors.occupancy" });

const roomSchema = z.object({
  number: z.string().trim().min(1, "validation.required").max(20),
  room_type_id: z.string().uuid("validation.required"),
  floor: z.string().max(20).optional(),
  building: z.string().max(60).optional(),
  notes: z.string().max(1000).optional(),
  is_active: z.boolean(),
});

const rateSchema = z.object({
  name: z.string().trim().min(1, "validation.required").max(120),
  starts_on: z.string().min(1, "validation.required"),
  ends_on: z.string().min(1, "validation.required"),
  price_per_night: money,
}).refine((v) => v.ends_on >= v.starts_on, { path: ["ends_on"], message: "bookings.errors.dates" });

/** Номерной фонд: категории с ценами, сезонные цены и номера */
export function RoomsPage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable } = useOrg();
  const qc = useQueryClient();
  const canWrite = can("rooms.write") && writable;
  const canStatus = (can("rooms.status") || can("rooms.write")) && writable;
  const canDelete = can("rooms.delete") && writable;

  const types = useRoomTypes(org.id);
  const rooms = useRooms(org.id);
  const [typeDialog, setTypeDialog] = useState<RoomType | "new" | null>(null);
  const [roomDialog, setRoomDialog] = useState<Room | "new" | null>(null);
  const [ratesFor, setRatesFor] = useState<RoomType | null>(null);
  const [toDelete, setToDelete] = useState<Room | null>(null);

  const typeName = (id: string) => types.data?.find((x) => x.id === id)?.name ?? "—";
  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: ["rooms", org.id] });
    void qc.invalidateQueries({ queryKey: ["room-types", org.id] });
  };

  const setStatus = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: RoomStatus }) => {
      const { error } = await supabase.rpc("set_room_status", { p_room_id: id, p_status: status });
      if (error) throw error;
    },
    onSuccess: () => toast.success(t("common.saved")),
    onError: (e) => toast.error(describeBookingError(e, t)),
    onSettled: invalidate,
  });

  const deleteRoom = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from("rooms").delete().eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => toast.success(t("rooms.deleted")),
    onError: (e) => toast.error(describeBookingError(e, t)),
    onSettled: invalidate,
  });

  if (types.error) return <ErrorState error={types.error} onRetry={() => types.refetch()} />;
  if (rooms.error) return <ErrorState error={rooms.error} onRetry={() => rooms.refetch()} />;
  const loading = types.isLoading || rooms.isLoading;
  const hasTypes = (types.data?.length ?? 0) > 0;

  return (
    <>
      <PageHeader
        title={t("rooms.title")}
        description={t("rooms.subtitle")}
        actions={canWrite && (
          <>
            <Button variant="outline" onClick={() => setTypeDialog("new")}><Plus /> {t("rooms.addType")}</Button>
            {hasTypes && <Button onClick={() => setRoomDialog("new")}><Plus /> {t("rooms.addRoom")}</Button>}
          </>
        )}
      />

      {loading ? (
        <div className="grid gap-3">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-16" />)}</div>
      ) : !hasTypes ? (
        <EmptyState
          icon={<BedDouble className="h-5 w-5" />}
          title={t("rooms.emptyTitle")}
          text={t("rooms.emptyText")}
          action={canWrite && <Button className="mt-2" onClick={() => setTypeDialog("new")}><Plus /> {t("rooms.addType")}</Button>}
        />
      ) : (
        <div className="grid gap-4">
          <Card>
            <CardHeader>
              <CardTitle>{t("rooms.typesTitle")}</CardTitle>
              <CardDescription>{t("rooms.typesText")}</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="-mx-5 overflow-x-auto">
                <table className="w-full min-w-[640px] text-sm">
                  <thead>
                    <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
                      <th className="px-5 py-2 font-medium">{t("rooms.colType")}</th>
                      <th className="px-5 py-2 font-medium">{t("rooms.colOccupancy")}</th>
                      <th className="px-5 py-2 font-medium">{t("rooms.colPrice")}</th>
                      <th className="px-5 py-2 font-medium">{t("rooms.colRooms")}</th>
                      <th className="px-5 py-2" />
                    </tr>
                  </thead>
                  <tbody className="divide-y">
                    {types.data!.map((rt) => (
                      <tr key={rt.id} className={rt.is_active ? "" : "text-muted-foreground"}>
                        <td className="px-5 py-2.5">
                          <span className="font-medium">{rt.name}</span>
                          <span className="ml-2 inline-flex gap-1">
                            {!rt.is_active && <Badge variant="secondary">{t("rooms.inactive")}</Badge>}
                            {rt.is_active && !rt.is_public && <Badge variant="outline">{t("rooms.hidden")}</Badge>}
                          </span>
                        </td>
                        <td className="px-5 py-2.5">{t("rooms.occupancyValue", { base: rt.base_occupancy, max: rt.max_occupancy })}</td>
                        <td className="px-5 py-2.5">
                          {formatKzt(rt.base_price, lang)}
                          {Number(rt.extra_guest_price) > 0 && (
                            <span className="block text-xs text-muted-foreground">{t("rooms.extraValue", { price: formatKzt(rt.extra_guest_price, lang) })}</span>
                          )}
                        </td>
                        <td className="px-5 py-2.5">{rooms.data!.filter((r) => r.room_type_id === rt.id).length}</td>
                        <td className="px-5 py-2.5 text-right whitespace-nowrap">
                          <Button size="sm" variant="ghost" onClick={() => setRatesFor(rt)}><CalendarDays /> {t("rooms.seasons")}</Button>
                          {canWrite && (
                            <Button size="icon" variant="ghost" aria-label={t("common.edit")} onClick={() => setTypeDialog(rt)}><Pencil /></Button>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>{t("rooms.roomsTitle")}</CardTitle></CardHeader>
            <CardContent>
              {rooms.data!.length === 0 ? (
                <EmptyState icon={<BedDouble className="h-5 w-5" />} title={t("rooms.noRooms")}
                  action={canWrite && <Button className="mt-2" onClick={() => setRoomDialog("new")}><Plus /> {t("rooms.addRoom")}</Button>} />
              ) : (
                <div className="-mx-5 overflow-x-auto">
                  <table className="w-full min-w-[600px] text-sm">
                    <thead>
                      <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
                        <th className="px-5 py-2 font-medium">{t("rooms.colNumber")}</th>
                        <th className="px-5 py-2 font-medium">{t("rooms.colType")}</th>
                        <th className="px-5 py-2 font-medium">{t("rooms.colFloor")}</th>
                        <th className="px-5 py-2 font-medium">{t("rooms.colStatus")}</th>
                        <th className="px-5 py-2" />
                      </tr>
                    </thead>
                    <tbody className="divide-y">
                      {rooms.data!.map((r) => (
                        <tr key={r.id} className={r.is_active ? "" : "text-muted-foreground"}>
                          <td className="px-5 py-2.5 font-medium">
                            {r.number}
                            {!r.is_active && <Badge variant="secondary" className="ml-2">{t("rooms.inactive")}</Badge>}
                          </td>
                          <td className="px-5 py-2.5">{typeName(r.room_type_id)}</td>
                          <td className="px-5 py-2.5">{[r.building, r.floor].filter(Boolean).join(", ") || "—"}</td>
                          <td className="px-5 py-2.5">
                            {canStatus && r.status !== "occupied" ? (
                              <NativeSelect className="h-8 w-40" value={r.status} aria-label={t("rooms.colStatus")}
                                onChange={(e) => setStatus.mutate({ id: r.id, status: e.target.value as RoomStatus })}>
                                {ROOM_STATUSES.filter((s) => s !== "occupied").map((s) => (
                                  <option key={s} value={s}>{t(`rooms.status.${s}`)}</option>
                                ))}
                              </NativeSelect>
                            ) : (
                              <Badge variant={roomStatusVariant[r.status]}>{t(`rooms.status.${r.status}`)}</Badge>
                            )}
                          </td>
                          <td className="px-5 py-2.5 text-right whitespace-nowrap">
                            {canWrite && <Button size="icon" variant="ghost" aria-label={t("common.edit")} onClick={() => setRoomDialog(r)}><Pencil /></Button>}
                            {canDelete && <Button size="icon" variant="ghost" className="text-destructive" aria-label={t("common.delete")} onClick={() => setToDelete(r)}><Trash2 /></Button>}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </CardContent>
          </Card>
        </div>
      )}

      {typeDialog && <RoomTypeDialog value={typeDialog === "new" ? null : typeDialog} onClose={() => setTypeDialog(null)} onSaved={invalidate} />}
      {roomDialog && types.data && (
        <RoomDialog value={roomDialog === "new" ? null : roomDialog} types={types.data} onClose={() => setRoomDialog(null)} onSaved={invalidate} />
      )}
      {ratesFor && <RatesDialog roomType={ratesFor} canWrite={canWrite} onClose={() => setRatesFor(null)} />}
      <ConfirmDialog
        open={toDelete !== null}
        onOpenChange={(o) => !o && setToDelete(null)}
        title={t("rooms.deleteTitle", { number: toDelete?.number ?? "" })}
        description={t("rooms.deleteText")}
        confirmLabel={t("common.delete")}
        cancelLabel={t("common.cancel")}
        destructive
        onConfirm={() => { if (toDelete) deleteRoom.mutate(toDelete.id); setToDelete(null); }}
      />
    </>
  );
}

function fieldError(t: (k: string) => string, e?: { message?: string }) {
  return e?.message ? t(e.message) : undefined;
}

function RoomTypeDialog({ value, onClose, onSaved }: { value: RoomType | null; onClose: () => void; onSaved: () => void }) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const form = useForm<z.infer<typeof roomTypeSchema>>({
    resolver: zodResolver(roomTypeSchema),
    defaultValues: value
      ? { ...value, description: value.description ?? "", base_price: Number(value.base_price), extra_guest_price: Number(value.extra_guest_price) }
      : { name: "", description: "", base_occupancy: 2, max_occupancy: 2, base_price: 0, extra_guest_price: 0, is_public: true, is_active: true },
  });
  const e = form.formState.errors;

  const onSubmit = form.handleSubmit(async (v) => {
    const row = { ...v, description: v.description?.trim() || null };
    const { error } = value
      ? await supabase.from("room_types").update(row).eq("id", value.id)
      : await supabase.from("room_types").insert({ ...row, tenant_id: org.id });
    if (error) { toast.error(describeBookingError(error, t)); return; }
    toast.success(t("common.saved"));
    onSaved();
    onClose();
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={value ? t("rooms.editType") : t("rooms.addType")}>
      <form onSubmit={onSubmit} className="grid gap-3" noValidate>
        <FormField id="rt-name" label={t("rooms.fields.typeName")} error={fieldError(t, e.name)}>
          <Input id="rt-name" placeholder={t("rooms.fields.typeNamePlaceholder")} {...form.register("name")} />
        </FormField>
        <FormField id="rt-desc" label={`${t("rooms.fields.description")} (${t("common.optional")})`}>
          <Textarea id="rt-desc" rows={3} {...form.register("description")} />
        </FormField>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="rt-base-occ" label={t("rooms.fields.baseOccupancy")} error={fieldError(t, e.base_occupancy)}>
            <Input id="rt-base-occ" type="number" min={1} {...form.register("base_occupancy")} />
          </FormField>
          <FormField id="rt-max-occ" label={t("rooms.fields.maxOccupancy")} error={fieldError(t, e.max_occupancy)}>
            <Input id="rt-max-occ" type="number" min={1} {...form.register("max_occupancy")} />
          </FormField>
          <FormField id="rt-price" label={t("rooms.fields.basePrice")} error={fieldError(t, e.base_price)}>
            <Input id="rt-price" type="number" min={0} step="100" {...form.register("base_price")} />
          </FormField>
          <FormField id="rt-extra" label={t("rooms.fields.extraPrice")} error={fieldError(t, e.extra_guest_price)}>
            <Input id="rt-extra" type="number" min={0} step="100" {...form.register("extra_guest_price")} />
          </FormField>
        </div>
        <p className="text-xs text-muted-foreground">{t("rooms.priceHint")}</p>
        <label className="flex items-center gap-2 text-sm">
          <Checkbox checked={form.watch("is_public")} onCheckedChange={(c) => form.setValue("is_public", c === true)} />
          {t("rooms.fields.isPublic")}
        </label>
        <label className="flex items-center gap-2 text-sm">
          <Checkbox checked={form.watch("is_active")} onCheckedChange={(c) => form.setValue("is_active", c === true)} />
          {t("rooms.fields.isActive")}
        </label>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={form.formState.isSubmitting}>{form.formState.isSubmitting ? t("common.saving") : t("common.save")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}

function RoomDialog({ value, types, onClose, onSaved }: { value: Room | null; types: RoomType[]; onClose: () => void; onSaved: () => void }) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const form = useForm<z.infer<typeof roomSchema>>({
    resolver: zodResolver(roomSchema),
    defaultValues: value
      ? { number: value.number, room_type_id: value.room_type_id, floor: value.floor ?? "", building: value.building ?? "", notes: value.notes ?? "", is_active: value.is_active }
      : { number: "", room_type_id: types.find((x) => x.is_active)?.id ?? "", floor: "", building: "", notes: "", is_active: true },
  });
  const e = form.formState.errors;

  const onSubmit = form.handleSubmit(async (v) => {
    const row = { ...v, number: v.number.trim(), floor: v.floor?.trim() || null, building: v.building?.trim() || null, notes: v.notes?.trim() || null };
    const { error } = value
      ? await supabase.from("rooms").update(row).eq("id", value.id)
      : await supabase.from("rooms").insert({ ...row, tenant_id: org.id });
    if (error) { toast.error(describeBookingError(error, t)); return; }
    toast.success(t("common.saved"));
    onSaved();
    onClose();
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={value ? t("rooms.editRoom", { number: value.number }) : t("rooms.addRoom")}>
      <form onSubmit={onSubmit} className="grid gap-3" noValidate>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="room-number" label={t("rooms.fields.number")} error={fieldError(t, e.number)}>
            <Input id="room-number" placeholder="101" {...form.register("number")} />
          </FormField>
          <FormField id="room-type" label={t("rooms.colType")} error={fieldError(t, e.room_type_id)}>
            <NativeSelect id="room-type" {...form.register("room_type_id")}>
              {types.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="room-building" label={`${t("rooms.fields.building")} (${t("common.optional")})`}>
            <Input id="room-building" {...form.register("building")} />
          </FormField>
          <FormField id="room-floor" label={`${t("rooms.fields.floor")} (${t("common.optional")})`}>
            <Input id="room-floor" {...form.register("floor")} />
          </FormField>
        </div>
        <FormField id="room-notes" label={`${t("rooms.fields.notes")} (${t("common.optional")})`}>
          <Textarea id="room-notes" rows={2} {...form.register("notes")} />
        </FormField>
        <label className="flex items-center gap-2 text-sm">
          <Checkbox checked={form.watch("is_active")} onCheckedChange={(c) => form.setValue("is_active", c === true)} />
          {t("rooms.fields.roomActive")}
        </label>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={form.formState.isSubmitting}>{form.formState.isSubmitting ? t("common.saving") : t("common.save")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}

function RatesDialog({ roomType, canWrite, onClose }: { roomType: RoomType; canWrite: boolean; onClose: () => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const rates = useQuery({
    queryKey: ["room-rates", roomType.id],
    queryFn: async () => {
      const { data, error } = await supabase.from("room_rates").select("*").eq("room_type_id", roomType.id).order("starts_on");
      if (error) throw error;
      return data as RoomRate[];
    },
  });
  const form = useForm<z.infer<typeof rateSchema>>({
    resolver: zodResolver(rateSchema),
    defaultValues: { name: "", starts_on: "", ends_on: "", price_per_night: Number(roomType.base_price) },
  });
  const e = form.formState.errors;

  const onSubmit = form.handleSubmit(async (v) => {
    const { error } = await supabase.from("room_rates").insert({ ...v, tenant_id: org.id, room_type_id: roomType.id });
    if (error) { toast.error(describeBookingError(error, t)); return; }
    toast.success(t("common.saved"));
    form.reset({ name: "", starts_on: "", ends_on: "", price_per_night: v.price_per_night });
    void qc.invalidateQueries({ queryKey: ["room-rates", roomType.id] });
  });

  const remove = async (id: string) => {
    const { error } = await supabase.from("room_rates").delete().eq("id", id);
    if (error) toast.error(describeBookingError(error, t));
    void qc.invalidateQueries({ queryKey: ["room-rates", roomType.id] });
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("rooms.seasonsTitle", { name: roomType.name })} description={t("rooms.seasonsText", { price: formatKzt(roomType.base_price, lang) })} className="max-w-xl">
      {rates.isLoading ? (
        <Skeleton className="h-16" />
      ) : rates.error ? (
        <ErrorState error={rates.error} onRetry={() => rates.refetch()} />
      ) : rates.data!.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t("rooms.noSeasons")}</p>
      ) : (
        <ul className="divide-y rounded-md border">
          {rates.data!.map((r) => (
            <li key={r.id} className="flex items-center gap-3 px-3 py-2 text-sm">
              <div className="flex-1">
                <p className="font-medium">{r.name}</p>
                <p className="text-xs text-muted-foreground">{formatDate(r.starts_on, lang)} — {formatDate(r.ends_on, lang)}</p>
              </div>
              <span>{formatKzt(r.price_per_night, lang)}</span>
              {canWrite && (
                <Button size="icon" variant="ghost" className="text-destructive" aria-label={t("common.delete")} onClick={() => remove(r.id)}><Trash2 /></Button>
              )}
            </li>
          ))}
        </ul>
      )}
      {canWrite && (
        <form onSubmit={onSubmit} className="mt-4 grid gap-3 rounded-md border bg-muted/40 p-3" noValidate>
          <Label className="text-sm font-medium">{t("rooms.addSeason")}</Label>
          <div className="grid gap-3 sm:grid-cols-2">
            <FormField id="rate-name" label={t("rooms.fields.seasonName")} error={fieldError(t, e.name)}>
              <Input id="rate-name" placeholder={t("rooms.fields.seasonPlaceholder")} {...form.register("name")} />
            </FormField>
            <FormField id="rate-price" label={t("rooms.fields.seasonPrice")} error={fieldError(t, e.price_per_night)}>
              <Input id="rate-price" type="number" min={0} step="100" {...form.register("price_per_night")} />
            </FormField>
            <FormField id="rate-from" label={t("rooms.fields.from")} error={fieldError(t, e.starts_on)}>
              <Input id="rate-from" type="date" {...form.register("starts_on")} />
            </FormField>
            <FormField id="rate-to" label={t("rooms.fields.to")} error={fieldError(t, e.ends_on)}>
              <Input id="rate-to" type="date" {...form.register("ends_on")} />
            </FormField>
          </div>
          <div className="flex justify-end">
            <Button type="submit" size="sm" disabled={form.formState.isSubmitting}><Plus /> {t("rooms.addSeason")}</Button>
          </div>
        </form>
      )}
    </Dialog>
  );
}
