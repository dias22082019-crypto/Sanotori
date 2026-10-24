import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useSearchParams } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Download, Eye, EyeOff, MessageSquareReply, Pencil, Plus, Star, TicketPercent } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { formatDate, formatDateTime, formatKzt, formatNumber, type AppLanguage } from "@/lib/format";
import { downloadCsv, parseAmount } from "@/lib/finance";
import {
  PROMO_PATTERN, describeMarketingError, normalizePromoCode, promoValueText, starsText,
  type PromoCode, type PromoKind, type Review, type ReviewStatus,
} from "@/lib/marketing";
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
import { Stars } from "@/components/Stars";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";

const TABS = ["reviews", "promos"] as const;
type Tab = (typeof TABS)[number];

/** Отзывы гостей (модерация и ответы) и промокоды (модуль «marketing») */
export function MarketingPage() {
  const { t } = useTranslation();
  const { can, writable, hasFeature } = useOrg();
  const [params, setParams] = useSearchParams();
  const tab: Tab = params.get("tab") === "promos" ? "promos" : "reviews";
  const enabled = hasFeature("marketing");
  const canWrite = writable && enabled && can("marketing.write");
  const [promoDialog, setPromoDialog] = useState<"new" | PromoCode | null>(null);

  return (
    <>
      <PageHeader title={t("marketing.title")} description={t("marketing.subtitle")}
        actions={canWrite && tab === "promos" && <Button onClick={() => setPromoDialog("new")}><Plus /> {t("marketing.newPromo")}</Button>} />

      {!enabled && (
        <Card className="mb-4 border-warning/40 bg-warning/5">
          <CardContent className="py-3 text-sm">{t("marketing.planNote")}</CardContent>
        </Card>
      )}

      <div className="-mx-4 mb-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
        <div role="tablist" className="inline-flex gap-1 rounded-lg bg-muted p-1">
          {TABS.map((key) => (
            <button key={key} role="tab" aria-selected={tab === key}
              className={cn("whitespace-nowrap rounded-md px-3 py-1.5 text-sm", tab === key ? "bg-card font-medium shadow-sm" : "text-muted-foreground hover:text-foreground")}
              onClick={() => setParams({ tab: key }, { replace: true })}>
              {t(`marketing.tabs.${key}`)}
            </button>
          ))}
        </div>
      </div>

      {tab === "reviews" ? <Reviews canWrite={canWrite} /> : <Promos canWrite={canWrite} onEdit={setPromoDialog} />}
      {promoDialog && <PromoDialog promo={promoDialog === "new" ? null : promoDialog} onClose={() => setPromoDialog(null)} />}
    </>
  );
}

function Reviews({ canWrite }: { canWrite: boolean }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const qc = useQueryClient();
  const [status, setStatus] = useState<ReviewStatus | "">("");
  const [replying, setReplying] = useState<Review | null>(null);

  const summary = useQuery({
    queryKey: ["marketing", org.id, "summary"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("review_summary", { p_tenant: org.id });
      if (error) throw error;
      return data as { count: number; average: number | string | null; new: number; by_rating: Record<string, number> } | null;
    },
  });
  const reviews = useQuery({
    queryKey: ["marketing", org.id, "reviews", status],
    queryFn: async () => {
      let q = supabase.from("reviews")
        .select("id, booking_id, rating, comment, author_name, publish_consent, status, reply, created_at, booking:bookings(number, check_in, check_out, guest:guests(full_name))")
        .eq("tenant_id", org.id).order("created_at", { ascending: false }).limit(300);
      if (status) q = q.eq("status", status);
      const { data, error } = await q;
      if (error) throw error;
      return data as unknown as Review[];
    },
  });

  const moderate = async (r: Review, next: ReviewStatus, reply: string | null = r.reply) => {
    const { error } = await supabase.rpc("moderate_review", { p_review_id: r.id, p_status: next, p_reply: reply });
    if (error) return toast.error(describeMarketingError(error, t) ?? describeError(error, t));
    toast.success(t(`marketing.moderated.${next}`));
    void qc.invalidateQueries({ queryKey: ["marketing", org.id] });
    return true;
  };

  const rows = reviews.data ?? [];
  const s = summary.data;
  const exportCsv = () => downloadCsv("reviews.csv", [
    [t("marketing.csv.date"), t("marketing.csv.booking"), t("marketing.csv.rating"), t("marketing.csv.comment"), t("marketing.csv.author"), t("marketing.csv.status"), t("marketing.csv.reply")],
    ...rows.map((r) => [formatDate(r.created_at.slice(0, 10), lang), r.booking ? `№${r.booking.number}` : "", starsText(r.rating), r.comment, r.author_name,
      t(`marketing.reviewStatus.${r.status}`), r.reply]),
  ]);

  return (
    <>
      {s && s.count > 0 && (
        <div className="mb-4 grid gap-3 sm:grid-cols-3">
          <Card><CardContent className="pt-5">
            <p className="text-sm text-muted-foreground">{t("marketing.average")}</p>
            <p className="mt-1.5 flex items-center gap-2 text-2xl font-semibold tabular-nums">
              {formatNumber(s.average ?? 0, lang)} <Stars rating={Math.round(Number(s.average))} />
            </p>
            <p className="mt-0.5 text-xs text-muted-foreground">{t("marketing.reviewsCount", { count: s.count })}</p>
          </CardContent></Card>
          <Card><CardContent className="pt-5">
            <p className="text-sm text-muted-foreground">{t("marketing.awaiting")}</p>
            <p className="mt-1.5 text-2xl font-semibold tabular-nums">{s.new}</p>
            <p className="mt-0.5 text-xs text-muted-foreground">{t("marketing.awaitingNote")}</p>
          </CardContent></Card>
          <Card><CardContent className="grid gap-1 pt-5 text-xs">
            {["5", "4", "3", "2", "1"].map((k) => (
              <div key={k} className="grid grid-cols-[24px_1fr_28px] items-center gap-2">
                <span className="tabular-nums text-muted-foreground">{k}★</span>
                <div className="h-2 rounded-full bg-muted">
                  <div className="h-2 rounded-full bg-warning" style={{ width: `${s.count ? (s.by_rating[k] / s.count) * 100 : 0}%` }} />
                </div>
                <span className="text-right tabular-nums">{s.by_rating[k]}</span>
              </div>
            ))}
          </CardContent></Card>
        </div>
      )}

      <Card>
        <CardHeader className="flex-row flex-wrap items-center gap-2 space-y-0 pb-2">
          <NativeSelect className="w-full sm:w-56" aria-label={t("marketing.csv.status")} value={status} onChange={(e) => setStatus(e.target.value as ReviewStatus | "")}>
            <option value="">{t("marketing.allReviews")}</option>
            {(["new", "published", "hidden"] as const).map((k) => <option key={k} value={k}>{t(`marketing.reviewStatus.${k}`)}</option>)}
          </NativeSelect>
          <Button variant="outline" className="sm:ml-auto" disabled={rows.length === 0} onClick={exportCsv}><Download /> CSV</Button>
        </CardHeader>
        <CardContent>
          {reviews.isLoading ? <Skeleton className="h-40" /> : reviews.error ? <ErrorState error={reviews.error} onRetry={() => reviews.refetch()} /> :
            rows.length === 0 ? <EmptyState icon={<Star className="h-5 w-5" />} title={t("marketing.noReviews")} text={t("marketing.noReviewsText")} /> : (
              <ul className="divide-y">
                {rows.map((r) => (
                  <li key={r.id} className="grid gap-2 py-4">
                    <div className="flex flex-wrap items-center gap-2">
                      <Stars rating={r.rating} />
                      <Badge variant={r.status === "published" ? "success" : r.status === "hidden" ? "secondary" : "warning"}>{t(`marketing.reviewStatus.${r.status}`)}</Badge>
                      {!r.publish_consent && <Badge variant="outline">{t("marketing.noConsent")}</Badge>}
                      <span className="text-xs text-muted-foreground">
                        {formatDateTime(r.created_at, lang, org.timezone)}
                        {r.booking && ` · №${r.booking.number}, ${formatDate(r.booking.check_in, lang)} — ${formatDate(r.booking.check_out, lang)}`}
                        {r.booking?.guest && ` · ${r.booking.guest.full_name}`}
                      </span>
                    </div>
                    {r.comment ? <p className="whitespace-pre-line text-sm">{r.comment}</p> : <p className="text-sm text-muted-foreground">{t("marketing.noComment")}</p>}
                    {r.author_name && <p className="text-xs text-muted-foreground">{t("marketing.signedAs", { name: r.author_name })}</p>}
                    {r.reply && (
                      <div className="rounded-md border-l-2 border-primary bg-accent/40 px-3 py-2 text-sm">
                        <p className="text-xs font-medium text-muted-foreground">{t("marketing.ourReply")}</p>
                        <p className="whitespace-pre-line">{r.reply}</p>
                      </div>
                    )}
                    {canWrite && (
                      <div className="flex flex-wrap gap-2">
                        {r.status !== "published" && (
                          <Button size="sm" variant="outline" disabled={!r.publish_consent} title={!r.publish_consent ? t("marketing.noConsentHint") : undefined}
                            onClick={() => moderate(r, "published")}><Eye /> {t("marketing.publish")}</Button>
                        )}
                        {r.status !== "hidden" && <Button size="sm" variant="ghost" onClick={() => moderate(r, "hidden")}><EyeOff /> {t("marketing.hide")}</Button>}
                        <Button size="sm" variant="ghost" onClick={() => setReplying(r)}><MessageSquareReply /> {r.reply ? t("marketing.editReply") : t("marketing.reply")}</Button>
                      </div>
                    )}
                  </li>
                ))}
              </ul>
            )}
          <p className="mt-4 text-xs text-muted-foreground">{t("marketing.reviewsNote")}</p>
        </CardContent>
      </Card>

      {replying && <ReplyDialog review={replying} onSave={async (text) => { if (await moderate(replying, replying.status, text || null)) setReplying(null); }} onClose={() => setReplying(null)} />}
    </>
  );
}

function ReplyDialog({ review, onSave, onClose }: { review: Review; onSave: (text: string) => Promise<void>; onClose: () => void }) {
  const { t } = useTranslation();
  const [text, setText] = useState(review.reply ?? "");
  const [busy, setBusy] = useState(false);
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("marketing.replyTitle")} description={review.comment ?? undefined}>
      <FormField id="reply-text" label={t("marketing.ourReply")} hint={t("marketing.replyHint")}>
        <Textarea id="reply-text" rows={4} maxLength={2000} autoFocus value={text} onChange={(e) => setText(e.target.value)} />
      </FormField>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy} onClick={async () => { setBusy(true); await onSave(text.trim()); setBusy(false); }}>{busy ? t("common.saving") : t("common.save")}</Button>
      </DialogFooter>
    </Dialog>
  );
}

function Promos({ canWrite, onEdit }: { canWrite: boolean; onEdit: (p: PromoCode) => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  const promos = useQuery({
    queryKey: ["marketing", org.id, "promos"],
    queryFn: async () => {
      const { data, error } = await supabase.from("promo_codes")
        .select("id, code, description, kind, value, valid_from, valid_to, min_nights, max_uses, is_active")
        .eq("tenant_id", org.id).order("is_active", { ascending: false }).order("code");
      if (error) throw error;
      return data as PromoCode[];
    },
  });
  const usage = useQuery({
    queryKey: ["marketing", org.id, "usage"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("promo_code_usage", { p_tenant: org.id });
      if (error) throw error;
      return new Map(((data ?? []) as { promo_code_id: string; uses: number; discount: number }[]).map((u) => [u.promo_code_id, u]));
    },
  });

  if (promos.isLoading) return <Skeleton className="h-40" />;
  if (promos.error) return <ErrorState error={promos.error} onRetry={() => promos.refetch()} />;
  const rows = promos.data ?? [];
  if (rows.length === 0) return <EmptyState icon={<TicketPercent className="h-5 w-5" />} title={t("marketing.noPromos")} text={t("marketing.noPromosText")} />;

  return (
    <Card>
      <CardContent className="pt-2">
        <ul className="divide-y">
          {rows.map((p) => {
            const u = usage.data?.get(p.id);
            const terms = [
              p.valid_from || p.valid_to ? t("marketing.checkInBetween", { from: p.valid_from ? formatDate(p.valid_from, lang) : "…", to: p.valid_to ? formatDate(p.valid_to, lang) : "…" }) : null,
              p.min_nights > 1 ? t("marketing.minNights", { count: p.min_nights }) : null,
              p.max_uses ? t("marketing.maxUses", { count: p.max_uses }) : null,
            ].filter(Boolean).join(" · ");
            return (
              <li key={p.id} className={cn("flex flex-wrap items-center gap-x-4 gap-y-1 py-3", !p.is_active && "opacity-60")}>
                <span className="rounded-md bg-accent px-2 py-1 font-mono text-sm font-semibold text-accent-foreground">{p.code}</span>
                <div className="min-w-0 flex-1 basis-56">
                  <p className="text-sm font-medium">−{promoValueText(p, lang)}{p.description && <span className="font-normal text-muted-foreground"> · {p.description}</span>}</p>
                  <p className="text-xs text-muted-foreground">{terms || t("marketing.noTerms")}</p>
                </div>
                <div className="text-right text-xs text-muted-foreground">
                  <p>{t("marketing.used", { count: Number(u?.uses ?? 0) })}</p>
                  {u && Number(u.discount) > 0 && <p>{t("marketing.discountTotal", { value: formatKzt(u.discount, lang) })}</p>}
                </div>
                {!p.is_active && <Badge variant="secondary">{t("marketing.inactive")}</Badge>}
                {canWrite && <Button size="sm" variant="ghost" onClick={() => onEdit(p)} aria-label={t("common.edit")}><Pencil /></Button>}
              </li>
            );
          })}
        </ul>
        <p className="mt-3 text-xs text-muted-foreground">{t("marketing.promosNote")}</p>
      </CardContent>
    </Card>
  );
}

function PromoDialog({ promo, onClose }: { promo: PromoCode | null; onClose: () => void }) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [code, setCode] = useState(promo?.code ?? "");
  const [description, setDescription] = useState(promo?.description ?? "");
  const [kind, setKind] = useState<PromoKind>(promo?.kind ?? "percent");
  const [value, setValue] = useState(promo ? String(Number(promo.value)) : "");
  const [from, setFrom] = useState(promo?.valid_from ?? "");
  const [to, setTo] = useState(promo?.valid_to ?? "");
  const [minNights, setMinNights] = useState(String(promo?.min_nights ?? 1));
  const [maxUses, setMaxUses] = useState(promo?.max_uses ? String(promo.max_uses) : "");
  const [active, setActive] = useState(promo?.is_active ?? true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    setError(null);
    const c = normalizePromoCode(code);
    const v = parseAmount(value);
    const nights = Number(minNights);
    const uses = maxUses.trim() ? Number(maxUses) : null;
    if (!PROMO_PATTERN.test(c)) return setError(t("marketing.errors.code"));
    if (v === null || (kind === "percent" && v > 100)) return setError(t("marketing.errors.value"));
    if (!Number.isInteger(nights) || nights < 1 || nights > 365) return setError(t("marketing.errors.minNights"));
    if (uses !== null && (!Number.isInteger(uses) || uses < 1)) return setError(t("marketing.errors.maxUses"));
    if (from && to && to < from) return setError(t("marketing.errors.period"));
    const values = { code: c, description: description.trim() || null, kind, value: v, valid_from: from || null, valid_to: to || null,
      min_nights: nights, max_uses: uses, is_active: active };
    setBusy(true);
    const { error: e } = promo
      ? await supabase.from("promo_codes").update(values).eq("id", promo.id)
      : await supabase.from("promo_codes").insert({ tenant_id: org.id, ...values });
    setBusy(false);
    if (e) return setError(describeMarketingError(e, t) ?? describeError(e, t));
    toast.success(t("common.saved"));
    void qc.invalidateQueries({ queryKey: ["marketing", org.id] });
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={promo ? promo.code : t("marketing.newPromo")} description={t("marketing.promoDialogText")}>
      <div className="grid gap-4">
        <div className="grid grid-cols-2 gap-3">
          <FormField id="pc-code" label={t("marketing.fields.code")} hint={t("marketing.codeHint")}>
            <Input id="pc-code" autoFocus className="font-mono uppercase" maxLength={30} value={code} onChange={(e) => setCode(e.target.value)} />
          </FormField>
          <FormField id="pc-desc" label={t("marketing.fields.description")}>
            <Input id="pc-desc" maxLength={300} value={description} onChange={(e) => setDescription(e.target.value)} />
          </FormField>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="pc-kind" label={t("marketing.fields.kind")}>
            <NativeSelect id="pc-kind" value={kind} onChange={(e) => setKind(e.target.value as PromoKind)}>
              <option value="percent">{t("marketing.kind.percent")}</option>
              <option value="fixed">{t("marketing.kind.fixed")}</option>
            </NativeSelect>
          </FormField>
          <FormField id="pc-value" label={kind === "percent" ? t("marketing.fields.percent") : t("marketing.fields.amount")}>
            <Input id="pc-value" inputMode="decimal" value={value} onChange={(e) => setValue(e.target.value)} />
          </FormField>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="pc-from" label={t("marketing.fields.from")}>
            <Input id="pc-from" type="date" value={from} max={to || undefined} onChange={(e) => setFrom(e.target.value)} />
          </FormField>
          <FormField id="pc-to" label={t("marketing.fields.to")}>
            <Input id="pc-to" type="date" value={to} min={from || undefined} onChange={(e) => setTo(e.target.value)} />
          </FormField>
        </div>
        <p className="-mt-2 text-xs text-muted-foreground">{t("marketing.periodHint")}</p>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="pc-nights" label={t("marketing.fields.minNights")}>
            <Input id="pc-nights" inputMode="numeric" value={minNights} onChange={(e) => setMinNights(e.target.value)} />
          </FormField>
          <FormField id="pc-uses" label={t("marketing.fields.maxUses")} hint={t("marketing.maxUsesHint")}>
            <Input id="pc-uses" inputMode="numeric" value={maxUses} onChange={(e) => setMaxUses(e.target.value)} />
          </FormField>
        </div>
        {promo && (
          <label className="flex items-center gap-2 text-sm"><Checkbox checked={active} onCheckedChange={(v) => setActive(v === true)} /> {t("marketing.activeLabel")}</label>
        )}
        {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy} onClick={save}>{busy ? t("common.saving") : t("common.save")}</Button>
      </DialogFooter>
    </Dialog>
  );
}
