import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Copy, MessageCircle, Star, TicketPercent, X } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { formatKzt, whatsappLink, type AppLanguage } from "@/lib/format";
import type { Booking } from "@/lib/bookings";
import { describeMarketingError, normalizePromoCode, reviewUrl } from "@/lib/marketing";
import { useOrg } from "@/auth/OrgProvider";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

/**
 * Промокод и ссылка на отзыв в карточке брони (модуль «marketing»).
 * Скидку считает сервер (apply_promo_code); ссылку на отзыв сотрудник отправляет гостю сам.
 */
export function BookingMarketing({ booking }: { booking: Booking }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable, hasFeature } = useOrg();
  const qc = useQueryClient();
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [link, setLink] = useState<string | null>(null);

  const enabled = hasFeature("marketing");
  const open = ["new_request", "confirmed", "checked_in"].includes(booking.status);
  const canPromo = enabled && writable && can("bookings.write") && open;
  const canReview = enabled && writable && booking.status === "checked_out" && (can("bookings.checkin") || can("marketing.write"));

  const promo = useQuery({
    queryKey: ["booking-promo", org.id, booking.id],
    enabled: enabled && (can("bookings.write") || can("marketing.read")),
    queryFn: async () => {
      const { data, error } = await supabase.from("bookings")
        .select("discount_amount, promo:promo_codes(code)").eq("id", booking.id).maybeSingle();
      if (error) throw error;
      return data as unknown as { discount_amount: string | number; promo: { code: string } | null } | null;
    },
  });

  const refresh = () => {
    for (const key of ["booking-promo", "booking-balance", "bookings", "finance"]) void qc.invalidateQueries({ queryKey: [key, org.id] });
  };

  const apply = async (value: string | null) => {
    setBusy(true);
    const { error } = await supabase.rpc("apply_promo_code", { p_booking_id: booking.id, p_code: value });
    setBusy(false);
    if (error) return toast.error(describeMarketingError(error, t) ?? describeError(error, t));
    toast.success(value ? t("marketing.promoApplied") : t("marketing.promoRemoved"));
    setCode("");
    refresh();
  };

  const makeLink = async () => {
    setBusy(true);
    const { data, error } = await supabase.rpc("create_review_request", { p_booking_id: booking.id });
    setBusy(false);
    if (error) return toast.error(describeMarketingError(error, t) ?? describeError(error, t));
    setLink(reviewUrl(data as string));
  };

  const copy = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      toast.success(t("marketing.copied"));
    } catch {
      toast.error(t("marketing.copyFailed"));
    }
  };

  if (!enabled || (!promo.data?.promo && !canPromo && !canReview)) return null;
  const applied = promo.data?.promo;
  const message = link ? t("marketing.reviewMessage", { name: org.name, link }) : "";

  return (
    <section className="mt-5 border-t pt-4">
      {(applied || canPromo) && (
        <div className="grid gap-2">
          <h3 className="flex items-center gap-2 text-sm font-semibold"><TicketPercent className="h-4 w-4" /> {t("marketing.promoTitle")}</h3>
          {applied ? (
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="rounded-md bg-accent px-2 py-0.5 font-mono text-accent-foreground">{applied.code}</span>
              <span>{t("marketing.discountValue", { value: formatKzt(promo.data!.discount_amount, lang) })}</span>
              {canPromo && (
                <Button size="sm" variant="ghost" disabled={busy} onClick={() => apply(null)}><X /> {t("marketing.removePromo")}</Button>
              )}
            </div>
          ) : (
            <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); if (code.trim()) void apply(normalizePromoCode(code)); }}>
              <Input className="h-9 max-w-48 font-mono uppercase" placeholder="LETO10" maxLength={30} value={code}
                aria-label={t("marketing.promoCode")} onChange={(e) => setCode(e.target.value)} />
              <Button size="sm" type="submit" variant="outline" disabled={busy || !code.trim()}>{t("marketing.applyPromo")}</Button>
            </form>
          )}
        </div>
      )}

      {canReview && (
        <div className="mt-4 grid gap-2">
          <h3 className="flex items-center gap-2 text-sm font-semibold"><Star className="h-4 w-4" /> {t("marketing.reviewTitle")}</h3>
          {!link ? (
            <div>
              <Button size="sm" variant="outline" disabled={busy} onClick={makeLink}>{t("marketing.makeReviewLink")}</Button>
              <p className="mt-1 text-xs text-muted-foreground">{t("marketing.reviewLinkHint")}</p>
            </div>
          ) : (
            <div className="grid gap-2">
              <code className="block break-all rounded-md bg-muted px-2 py-1.5 text-xs">{link}</code>
              <div className="flex flex-wrap gap-2">
                <Button size="sm" variant="outline" onClick={() => copy(message)}><Copy /> {t("marketing.copyMessage")}</Button>
                {booking.guest?.phone && (
                  <Button size="sm" asChild>
                    <a href={whatsappLink(booking.guest.phone, message)} target="_blank" rel="noopener noreferrer"><MessageCircle /> WhatsApp</a>
                  </Button>
                )}
              </div>
            </div>
          )}
        </div>
      )}
    </section>
  );
}
