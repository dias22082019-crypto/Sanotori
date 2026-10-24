import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import type { PublicReviews } from "@/lib/marketing";
import { Stars } from "@/components/Stars";

/** Опубликованные отзывы на публичной странице санатория. Если отзывов нет или модуля нет — блок не показывается. */
export function PublicReviewsSection({ slug }: { slug: string }) {
  const { t, i18n } = useTranslation();
  const locale = i18n.language === "kk" ? "kk-KZ" : "ru-RU";
  const query = useQuery({
    queryKey: ["public-reviews", slug],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_public_reviews", { p_slug: slug });
      if (error) throw error;
      return data as PublicReviews | null;
    },
    retry: false,
  });
  const r = query.data;
  if (!r || !r.count) return null;
  const month = (m: string) => new Date(`${m}-01T00:00:00`).toLocaleDateString(locale, { month: "long", year: "numeric" });

  return (
    <section className="mt-10" aria-labelledby="public-reviews">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h2 id="public-reviews" className="text-lg font-semibold">{t("public.reviews")}</h2>
        <span className="flex items-center gap-2 text-sm text-muted-foreground">
          <Stars rating={Math.round(Number(r.average))} />
          <span className="tabular-nums">{Number(r.average).toLocaleString(locale)}</span>
          · {t("marketing.reviewsCount", { count: r.count })}
        </span>
      </div>
      <ul className="mt-4 grid gap-3">
        {r.items.map((it, i) => (
          <li key={i} className="rounded-lg border bg-card p-4">
            <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
              <Stars rating={it.rating} />
              <span className="text-sm font-medium">{it.author_name || t("public.guest")}</span>
              <span className="text-xs text-muted-foreground">{month(it.month)}</span>
            </div>
            {it.comment && <p className="mt-2 whitespace-pre-line text-sm text-foreground/90">{it.comment}</p>}
            {it.reply && (
              <div className="mt-3 rounded-md border-l-2 border-primary bg-accent/40 px-3 py-2 text-sm">
                <p className="text-xs font-medium text-muted-foreground">{t("public.reviewReply")}</p>
                <p className="whitespace-pre-line">{it.reply}</p>
              </div>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
