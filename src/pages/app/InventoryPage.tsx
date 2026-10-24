import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useSearchParams } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowDownToLine, ArrowUpFromLine, ClipboardList, Download, Package, Pencil, Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { formatDateTime, formatKzt, todayInTimeZone, zonedDateTime, type AppLanguage } from "@/lib/format";
import { addDays } from "@/lib/bookings";
import { downloadCsv, parseAmount } from "@/lib/finance";
import {
  INVENTORY_CATEGORIES, MOVE_KINDS, UNIT_SUGGESTIONS, balanceAfter, describeInventoryError, formatQty, parseQuantity, stockLevel,
  type InventoryCategory, type InventoryItem, type InventoryMovement, type MoveKind,
} from "@/lib/inventory";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect, Textarea } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";

const TABS = ["stock", "history"] as const;
type Tab = (typeof TABS)[number];
const ITEM_SELECT = "id, name, category, unit, quantity, min_quantity, is_active";

function useItems(tenantId: string) {
  return useQuery({
    queryKey: ["inventory", tenantId, "items"],
    queryFn: async () => {
      const { data, error } = await supabase.from("inventory_items").select(ITEM_SELECT).eq("tenant_id", tenantId).order("name");
      if (error) throw error;
      return data as InventoryItem[];
    },
  });
}

/** Склад: остатки с минимумами, приход, выдача, списание, пересчёт и история движений */
export function InventoryPage() {
  const { t } = useTranslation();
  const { org, can, writable, hasFeature } = useOrg();
  const [params, setParams] = useSearchParams();
  const tab: Tab = params.get("tab") === "history" ? "history" : "stock";
  const enabled = hasFeature("inventory");
  const canWrite = writable && enabled && can("inventory.write");
  const items = useItems(org.id);
  const [itemDialog, setItemDialog] = useState<"new" | InventoryItem | null>(null);

  return (
    <>
      <PageHeader title={t("inventory.title")} description={t("inventory.subtitle")}
        actions={canWrite && tab === "stock" && <Button onClick={() => setItemDialog("new")}><Plus /> {t("inventory.newItem")}</Button>} />

      {!enabled && (
        <Card className="mb-4 border-warning/40 bg-warning/5">
          <CardContent className="py-3 text-sm">{t("inventory.planNote")}</CardContent>
        </Card>
      )}

      <div className="-mx-4 mb-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
        <div role="tablist" className="inline-flex gap-1 rounded-lg bg-muted p-1">
          {TABS.map((key) => (
            <button key={key} role="tab" aria-selected={tab === key}
              className={cn("whitespace-nowrap rounded-md px-3 py-1.5 text-sm", tab === key ? "bg-card font-medium shadow-sm" : "text-muted-foreground hover:text-foreground")}
              onClick={() => setParams({ tab: key }, { replace: true })}>
              {t(`inventory.tabs.${key}`)}
            </button>
          ))}
        </div>
      </div>

      {tab === "stock"
        ? <Stock items={items} canWrite={canWrite} onEdit={setItemDialog} />
        : <History items={items.data ?? []} />}

      {itemDialog && <ItemDialog item={itemDialog === "new" ? null : itemDialog} onClose={() => setItemDialog(null)} />}
    </>
  );
}

function Stock({ items, canWrite, onEdit }: {
  items: ReturnType<typeof useItems>;
  canWrite: boolean;
  onEdit: (item: InventoryItem) => void;
}) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const [category, setCategory] = useState<InventoryCategory | "">("");
  const [search, setSearch] = useState("");
  const [lowOnly, setLowOnly] = useState(false);
  const [archived, setArchived] = useState(false);
  const [move, setMove] = useState<{ item: InventoryItem; kind: MoveKind } | null>(null);

  const all = items.data ?? [];
  const low = all.filter((i) => i.is_active && stockLevel(i) !== "ok" && Number(i.min_quantity) > 0);
  const list = all.filter((i) => (archived ? !i.is_active : i.is_active)
    && (!category || i.category === category)
    && (!search || i.name.toLowerCase().includes(search.trim().toLowerCase()))
    && (!lowOnly || low.includes(i)));

  const exportCsv = () => downloadCsv(`stock_${todayInTimeZone(org.timezone)}.csv`, [
    [t("inventory.fields.name"), t("inventory.fields.category"), t("inventory.fields.quantity"), t("inventory.fields.unit"), t("inventory.fields.min")],
    ...list.map((i) => [i.name, t(`inventory.categories.${i.category}`), Number(i.quantity), i.unit, Number(i.min_quantity)]),
  ]);

  if (items.isLoading) return <Skeleton className="h-48" />;
  if (items.error) return <ErrorState error={items.error} onRetry={() => items.refetch()} />;
  if (all.length === 0) {
    return <EmptyState icon={<Package className="h-5 w-5" />} title={t("inventory.emptyTitle")} text={t("inventory.emptyText")} />;
  }

  return (
    <>
      {low.length > 0 && (
        <Card className="mb-4 border-warning/40 bg-warning/5">
          <CardContent className="flex flex-wrap items-center gap-x-3 gap-y-1 py-3 text-sm">
            <span className="font-medium">{t("inventory.lowBanner", { count: low.length })}</span>
            <span className="text-muted-foreground">{low.slice(0, 5).map((i) => i.name).join(", ")}{low.length > 5 && "…"}</span>
            {!lowOnly && <Button size="sm" variant="outline" className="ml-auto" onClick={() => setLowOnly(true)}>{t("inventory.showLow")}</Button>}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader className="pb-2">
          <div className="grid gap-3 sm:grid-cols-[1fr_200px_auto] sm:items-center">
            <Input type="search" placeholder={t("inventory.search")} aria-label={t("inventory.search")} value={search} onChange={(e) => setSearch(e.target.value)} />
            <NativeSelect aria-label={t("inventory.fields.category")} value={category} onChange={(e) => setCategory(e.target.value as InventoryCategory | "")}>
              <option value="">{t("inventory.allCategories")}</option>
              {INVENTORY_CATEGORIES.map((c) => <option key={c} value={c}>{t(`inventory.categories.${c}`)}</option>)}
            </NativeSelect>
            <Button variant="outline" disabled={list.length === 0} onClick={exportCsv}><Download /> CSV</Button>
          </div>
          <div className="flex flex-wrap gap-x-5 gap-y-2 pt-2 text-sm">
            <label className="flex items-center gap-2"><Checkbox checked={lowOnly} onCheckedChange={(v) => setLowOnly(v === true)} /> {t("inventory.lowOnly")}</label>
            <label className="flex items-center gap-2"><Checkbox checked={archived} onCheckedChange={(v) => setArchived(v === true)} /> {t("inventory.archived")}</label>
          </div>
        </CardHeader>
        <CardContent>
          {list.length === 0 ? <p className="py-6 text-center text-sm text-muted-foreground">{t("inventory.nothingFound")}</p> : (
            <ul className="divide-y">
              {list.map((i) => {
                const level = stockLevel(i);
                return (
                  <li key={i.id} className="flex flex-wrap items-center gap-x-4 gap-y-2 py-3">
                    <div className="min-w-0 flex-1 basis-48">
                      <p className="font-medium">{i.name}</p>
                      <p className="text-xs text-muted-foreground">
                        {t(`inventory.categories.${i.category}`)}
                        {Number(i.min_quantity) > 0 && ` · ${t("inventory.minShort", { value: `${formatQty(i.min_quantity, lang)} ${i.unit}` })}`}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      <span className="text-lg font-semibold tabular-nums">{formatQty(i.quantity, lang)}</span>
                      <span className="text-sm text-muted-foreground">{i.unit}</span>
                      {level === "out" && <Badge variant="destructive">{t("inventory.level.out")}</Badge>}
                      {level === "low" && Number(i.min_quantity) > 0 && <Badge variant="warning">{t("inventory.level.low")}</Badge>}
                    </div>
                    {canWrite && i.is_active && (
                      <div className="flex w-full flex-wrap gap-1.5 sm:w-auto">
                        <Button size="sm" variant="outline" onClick={() => setMove({ item: i, kind: "receipt" })}><ArrowDownToLine /> {t("inventory.kinds.receipt")}</Button>
                        <Button size="sm" variant="outline" disabled={level === "out"} onClick={() => setMove({ item: i, kind: "issue" })}><ArrowUpFromLine /> {t("inventory.kinds.issue")}</Button>
                        <Button size="sm" variant="ghost" disabled={level === "out"} onClick={() => setMove({ item: i, kind: "writeoff" })} aria-label={t("inventory.kinds.writeoff")} title={t("inventory.kinds.writeoff")}><Trash2 /></Button>
                        <Button size="sm" variant="ghost" onClick={() => setMove({ item: i, kind: "adjustment" })} aria-label={t("inventory.kinds.adjustment")} title={t("inventory.kinds.adjustment")}><ClipboardList /></Button>
                        <Button size="sm" variant="ghost" onClick={() => onEdit(i)} aria-label={t("common.edit")} title={t("common.edit")}><Pencil /></Button>
                      </div>
                    )}
                    {canWrite && !i.is_active && (
                      <Button size="sm" variant="ghost" onClick={() => onEdit(i)}><Pencil /> {t("common.edit")}</Button>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </CardContent>
      </Card>

      {move && <MoveDialog item={move.item} kind={move.kind} onClose={() => setMove(null)} />}
    </>
  );
}

function MoveDialog({ item, kind, onClose }: { item: InventoryItem; kind: MoveKind; onClose: () => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const [qty, setQty] = useState("");
  const [cost, setCost] = useState("");
  const [room, setRoom] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const rooms = useQuery({
    queryKey: ["inventory", org.id, "rooms"],
    enabled: kind === "issue",
    queryFn: async () => {
      const { data, error } = await supabase.from("rooms").select("id, number").eq("tenant_id", org.id).eq("is_active", true).order("number");
      if (error) throw error;
      return data as { id: string; number: string }[];
    },
  });

  const current = Number(item.quantity);
  const parsed = parseQuantity(qty, kind === "adjustment");
  const after = parsed === null ? null : balanceAfter(kind, current, parsed);
  const unitCost = cost.trim() ? parseAmount(cost) : null;

  const save = async () => {
    setError(null);
    if (parsed === null) return setError(t("inventory.errors.quantity"));
    if (after !== null && after < 0) return setError(t("inventory.errors.notEnough"));
    if (kind === "writeoff" && !note.trim()) return setError(t("inventory.errors.reason"));
    if (cost.trim() && unitCost === null) return setError(t("inventory.errors.cost"));
    setBusy(true);
    const { error: e } = await supabase.rpc("record_inventory_move", {
      p_item: item.id, p_kind: kind, p_quantity: parsed, p_note: note.trim() || null,
      p_unit_cost: kind === "receipt" ? unitCost : null, p_room: kind === "issue" && room ? room : null,
    });
    setBusy(false);
    if (e) return setError(describeInventoryError(e, t) ?? describeError(e, t));
    toast.success(t("inventory.saved"));
    void qc.invalidateQueries({ queryKey: ["inventory", org.id] });
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={`${t(`inventory.kinds.${kind}`)}: ${item.name}`}
      description={t(`inventory.kindHelp.${kind}`, { value: `${formatQty(current, lang)} ${item.unit}` })}>
      <div className="grid gap-4">
        <div className="grid grid-cols-2 gap-3">
          <FormField id="mv-qty" label={t(kind === "adjustment" ? "inventory.fields.counted" : "inventory.fields.amount", { unit: item.unit })}>
            <Input id="mv-qty" inputMode="decimal" autoFocus value={qty} onChange={(e) => setQty(e.target.value)} />
          </FormField>
          {kind === "receipt" && (
            <FormField id="mv-cost" label={t("inventory.fields.unitCost")} hint={t("inventory.costHint")}>
              <Input id="mv-cost" inputMode="decimal" value={cost} onChange={(e) => setCost(e.target.value)} />
            </FormField>
          )}
          {kind === "issue" && (
            <FormField id="mv-room" label={t("inventory.fields.room")}>
              <NativeSelect id="mv-room" value={room} onChange={(e) => setRoom(e.target.value)}>
                <option value="">{t("inventory.noRoom")}</option>
                {rooms.data?.map((r) => <option key={r.id} value={r.id}>{r.number}</option>)}
              </NativeSelect>
            </FormField>
          )}
        </div>
        <FormField id="mv-note" label={t(kind === "writeoff" ? "inventory.fields.reason" : "inventory.fields.note")}>
          <Textarea id="mv-note" rows={2} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)}
            placeholder={t(`inventory.notePlaceholder.${kind}`)} />
        </FormField>
        {after !== null && (
          <p className={cn("text-sm", after < 0 ? "text-destructive" : "text-muted-foreground")}>
            {t("inventory.after", { value: `${formatQty(after, lang)} ${item.unit}` })}
            {kind === "receipt" && unitCost !== null && parsed !== null && ` · ${t("inventory.total", { value: formatKzt(Math.round(unitCost * parsed * 100) / 100, lang) })}`}
          </p>
        )}
        {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy || !qty} onClick={save}>{busy ? t("common.saving") : t("common.save")}</Button>
      </DialogFooter>
    </Dialog>
  );
}

function ItemDialog({ item, onClose }: { item: InventoryItem | null; onClose: () => void }) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [name, setName] = useState(item?.name ?? "");
  const [category, setCategory] = useState<InventoryCategory>(item?.category ?? "linen");
  const [unit, setUnit] = useState(item?.unit ?? "шт");
  const [min, setMin] = useState(item ? String(Number(item.min_quantity)) : "");
  const [active, setActive] = useState(item?.is_active ?? true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    setError(null);
    const minQty = min.trim() ? parseQuantity(min, true) : 0;
    if (!name.trim()) return setError(t("inventory.errors.name"));
    if (!unit.trim()) return setError(t("inventory.errors.unit"));
    if (minQty === null) return setError(t("inventory.errors.quantity"));
    const values = { name: name.trim(), category, unit: unit.trim(), min_quantity: minQty, is_active: active };
    setBusy(true);
    const { error: e } = item
      ? await supabase.from("inventory_items").update(values).eq("id", item.id)
      : await supabase.from("inventory_items").insert({ tenant_id: org.id, ...values });
    setBusy(false);
    if (e) return setError(describeInventoryError(e, t) ?? describeError(e, t));
    toast.success(t("common.saved"));
    void qc.invalidateQueries({ queryKey: ["inventory", org.id] });
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={item ? item.name : t("inventory.newItem")}
      description={item ? undefined : t("inventory.newItemText")}>
      <div className="grid gap-4">
        <FormField id="it-name" label={t("inventory.fields.name")}>
          <Input id="it-name" autoFocus maxLength={200} value={name} onChange={(e) => setName(e.target.value)} />
        </FormField>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="it-cat" label={t("inventory.fields.category")}>
            <NativeSelect id="it-cat" value={category} onChange={(e) => setCategory(e.target.value as InventoryCategory)}>
              {INVENTORY_CATEGORIES.map((c) => <option key={c} value={c}>{t(`inventory.categories.${c}`)}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="it-unit" label={t("inventory.fields.unit")}>
            <Input id="it-unit" list="it-units" maxLength={20} value={unit} onChange={(e) => setUnit(e.target.value)} />
            <datalist id="it-units">{UNIT_SUGGESTIONS.map((u) => <option key={u} value={u} />)}</datalist>
          </FormField>
        </div>
        <FormField id="it-min" label={t("inventory.fields.min")} hint={t("inventory.minHint")}>
          <Input id="it-min" inputMode="decimal" value={min} onChange={(e) => setMin(e.target.value)} />
        </FormField>
        {item && (
          <label className="flex items-center gap-2 text-sm">
            <Checkbox checked={active} onCheckedChange={(v) => setActive(v === true)} /> {t("inventory.activeLabel")}
          </label>
        )}
        {!item && <p className="text-xs text-muted-foreground">{t("inventory.startHint")}</p>}
        {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy} onClick={save}>{busy ? t("common.saving") : t("common.save")}</Button>
      </DialogFooter>
    </Dialog>
  );
}

function History({ items }: { items: InventoryItem[] }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const tz = org.timezone;
  const today = todayInTimeZone(tz);
  const [from, setFrom] = useState(addDays(today, -29));
  const [to, setTo] = useState(today);
  const [itemId, setItemId] = useState("");
  const [kind, setKind] = useState<MoveKind | "">("");

  const moves = useQuery({
    queryKey: ["inventory", org.id, "moves", from, to, itemId, kind],
    queryFn: async () => {
      let q = supabase.from("inventory_movements")
        .select("id, item_id, kind, quantity, balance_after, unit_cost, room_id, note, created_by, created_at")
        .eq("tenant_id", org.id)
        .gte("created_at", zonedDateTime(from, "00:00", tz))
        .lt("created_at", zonedDateTime(addDays(to, 1), "00:00", tz))
        .order("created_at", { ascending: false }).limit(1000);
      if (itemId) q = q.eq("item_id", itemId);
      if (kind) q = q.eq("kind", kind);
      const { data, error } = await q;
      if (error) throw error;
      return data as InventoryMovement[];
    },
  });
  const rooms = useQuery({
    queryKey: ["inventory", org.id, "rooms"],
    queryFn: async () => {
      const { data, error } = await supabase.from("rooms").select("id, number").eq("tenant_id", org.id).order("number");
      if (error) throw error;
      return data as { id: string; number: string }[];
    },
  });
  const people = useQuery({
    queryKey: ["inventory", org.id, "people", moves.data?.length],
    enabled: !!moves.data?.length,
    queryFn: async () => {
      const ids = [...new Set(moves.data!.map((m) => m.created_by).filter(Boolean))] as string[];
      if (ids.length === 0) return new Map<string, string>();
      const { data, error } = await supabase.from("user_profiles").select("id, full_name").in("id", ids);
      if (error) throw error;
      return new Map((data ?? []).map((p) => [p.id as string, (p.full_name as string | null) || "—"]));
    },
  });

  const byId = new Map(items.map((i) => [i.id, i]));
  const roomNo = (id: string | null) => (id ? rooms.data?.find((r) => r.id === id)?.number ?? "" : "");
  const who = (id: string | null) => (id ? people.data?.get(id) ?? "—" : "—");
  const rows = moves.data ?? [];

  const exportCsv = () => downloadCsv(`stock_moves_${from}_${to}.csv`, [
    [t("inventory.csv.time"), t("inventory.fields.name"), t("inventory.csv.kind"), t("inventory.csv.change"), t("inventory.csv.balance"),
      t("inventory.fields.unit"), t("inventory.fields.unitCost"), t("inventory.fields.room"), t("inventory.fields.note"), t("inventory.csv.who")],
    ...rows.map((m) => {
      const it = byId.get(m.item_id);
      return [formatDateTime(m.created_at, lang, tz), it?.name ?? "", t(`inventory.kinds.${m.kind}`), Number(m.quantity), Number(m.balance_after),
        it?.unit ?? "", m.unit_cost === null ? null : Number(m.unit_cost), roomNo(m.room_id), m.note, who(m.created_by)];
    }),
  ]);

  return (
    <Card>
      <CardHeader className="pb-2">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-[150px_150px_1fr_180px_auto] lg:items-end">
          <FormField id="h-from" label={t("audit.from")}>
            <Input id="h-from" type="date" value={from} max={to} onChange={(e) => e.target.value && setFrom(e.target.value)} />
          </FormField>
          <FormField id="h-to" label={t("audit.to")}>
            <Input id="h-to" type="date" value={to} min={from} onChange={(e) => e.target.value && setTo(e.target.value)} />
          </FormField>
          <FormField id="h-item" label={t("inventory.fields.name")}>
            <NativeSelect id="h-item" value={itemId} onChange={(e) => setItemId(e.target.value)}>
              <option value="">{t("inventory.allItems")}</option>
              {items.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="h-kind" label={t("inventory.csv.kind")}>
            <NativeSelect id="h-kind" value={kind} onChange={(e) => setKind(e.target.value as MoveKind | "")}>
              <option value="">{t("inventory.allKinds")}</option>
              {MOVE_KINDS.map((k) => <option key={k} value={k}>{t(`inventory.kinds.${k}`)}</option>)}
            </NativeSelect>
          </FormField>
          <Button variant="outline" disabled={rows.length === 0} onClick={exportCsv}><Download /> CSV</Button>
        </div>
      </CardHeader>
      <CardContent>
        {moves.isLoading ? <Skeleton className="h-32" /> : moves.error ? <ErrorState error={moves.error} onRetry={() => moves.refetch()} /> :
          rows.length === 0 ? <p className="py-6 text-center text-sm text-muted-foreground">{t("inventory.noMoves")}</p> : (
            <ul className="divide-y">
              {rows.map((m) => {
                const it = byId.get(m.item_id);
                const q = Number(m.quantity);
                const details = [
                  m.room_id && t("inventory.toRoom", { number: roomNo(m.room_id) }),
                  m.unit_cost !== null && t("inventory.atCost", { value: formatKzt(m.unit_cost, lang) }),
                  m.note,
                ].filter(Boolean).join(" · ");
                return (
                  <li key={m.id} className="grid gap-x-4 gap-y-0.5 py-2.5 text-sm sm:grid-cols-[150px_1fr_auto]">
                    <span className="tabular-nums text-muted-foreground">{formatDateTime(m.created_at, lang, tz)}</span>
                    <span className="min-w-0">
                      <span className="font-medium">{it?.name ?? "—"}</span>
                      <span className="text-muted-foreground"> · {t(`inventory.kinds.${m.kind}`)} · {who(m.created_by)}</span>
                      {details && <span className="block break-words text-xs text-muted-foreground">{details}</span>}
                    </span>
                    <span className="whitespace-nowrap tabular-nums sm:text-right">
                      <span className={cn("font-medium", q > 0 ? "text-success" : q < 0 ? "text-destructive" : "")}>
                        {q > 0 ? "+" : q < 0 ? "−" : "±"}{formatQty(Math.abs(q), lang)}
                      </span>
                      <span className="text-muted-foreground"> → {formatQty(m.balance_after, lang)} {it?.unit}</span>
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
      </CardContent>
    </Card>
  );
}
