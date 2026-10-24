import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, Star } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { formatDate, type AppLanguage } from "@/lib/format";
import { describeMarketingError } from "@/lib/marketing";
import { describeError } from "@/lib/errors";
import { usePageMeta } from "@/lib/seo";
import { cn } from "@/lib/utils";
import { hasSavedLanguage } from "@/i18n";
import { Button } from "@/components/ui/button";
import { Input, Textarea } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Checkbox } from "@/components/ui/checkbox";
import { LanguageSwitcher } from "@/components/LanguageSwitcher";
import { LoadingScreen } from "@/components/states/LoadingScreen";
import { ErrorState } from "@/components/states/ErrorState";

interface ReviewForm {
  state: "not_found" | "used" | "expired" | "unavailable" | "open";
  sanatorium?: string;
  slug?: string | null;
  default_language?: AppLanguage;
  check_in?: string;
  check_out?: string;
}

/**
 * /review/:token — одноразовая форма отзыва гостя. Ссылку создаёт сотрудник после выезда.
 * Публикуется отзыв только с согласия гостя и после модерации санатория.
 */
export function ReviewPage() {
  const { token = "" } = useParams();
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const form = useQuery({
    queryKey: ["review-form", token],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_review_form", { p_token: token });
      if (error) throw error;
      return data as ReviewForm;
    },
  });
  const f = form.data;
  const [rating, setRating] = useState(0);
  const [hover, setHover] = useState(0);
  const [comment, setComment] = useState("");
  const [name, setName] = useState("");
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  useEffect(() => {
    if (f?.default_language && !hasSavedLanguage() && i18n.language !== f.default_language) void i18n.changeLanguage(f.default_language);
  }, [f, i18n]);
  usePageMeta(f?.sanatorium ? t("review.metaTitle", { name: f.sanatorium }) : t("review.title"));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    if (rating < 1) return setError(t("review.chooseRating"));
    setBusy(true);
    const { error: err } = await supabase.rpc("submit_review", {
      p_token: token, p_rating: rating, p_comment: comment.trim() || null,
      p_author_name: name.trim() || null, p_publish_consent: consent,
    });
    setBusy(false);
    if (err) return setError(describeMarketingError(err, t) ?? describeError(err, t));
    setDone(true);
  };

  if (form.isLoading) return <LoadingScreen />;
  if (form.error) return <ErrorState error={form.error} onRetry={() => form.refetch()} />;

  const closed = !f || f.state !== "open";
  return (
    <div className="min-h-screen bg-background">
      <header className="border-b bg-card">
        <div className="mx-auto flex max-w-xl items-center justify-between gap-4 px-4 py-3">
          <span className="truncate font-semibold">{f?.sanatorium ?? t("review.title")}</span>
          <LanguageSwitcher />
        </div>
      </header>
      <main className="mx-auto max-w-xl px-4 py-10">
        {done ? (
          <div className="text-center">
            <CheckCircle2 className="mx-auto h-10 w-10 text-success" />
            <h1 className="mt-3 text-xl font-semibold">{t("review.thanksTitle")}</h1>
            <p className="mt-2 text-sm text-muted-foreground">{consent ? t("review.thanksPublic") : t("review.thanksPrivate")}</p>
            {f?.slug && <Button asChild variant="outline" className="mt-6"><Link to={`/s/${f.slug}`}>{t("review.toSite")}</Link></Button>}
          </div>
        ) : closed ? (
          <div className="text-center">
            <h1 className="text-xl font-semibold">{t(`review.state.${f?.state ?? "not_found"}.title`)}</h1>
            <p className="mt-2 text-sm text-muted-foreground">{t(`review.state.${f?.state ?? "not_found"}.text`)}</p>
            {f?.slug && <Button asChild variant="outline" className="mt-6"><Link to={`/s/${f.slug}`}>{t("review.toSite")}</Link></Button>}
          </div>
        ) : (
          <form onSubmit={submit} className="grid gap-5" noValidate>
            <div>
              <h1 className="text-2xl font-semibold tracking-tight">{t("review.heading")}</h1>
              {f.check_in && f.check_out && (
                <p className="mt-1 text-sm text-muted-foreground">{t("review.stay", { from: formatDate(f.check_in, lang), to: formatDate(f.check_out, lang) })}</p>
              )}
            </div>
            <fieldset>
              <legend className="mb-2 text-sm font-medium">{t("review.ratingLabel")}</legend>
              <div className="flex gap-1" role="radiogroup" aria-label={t("review.ratingLabel")} onMouseLeave={() => setHover(0)}>
                {[1, 2, 3, 4, 5].map((i) => (
                  <button key={i} type="button" role="radio" aria-checked={rating === i} aria-label={t("review.starLabel", { count: i })}
                    className="rounded-md p-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                    onMouseEnter={() => setHover(i)} onClick={() => setRating(i)}>
                    <Star className={cn("h-9 w-9 transition-colors", i <= (hover || rating) ? "fill-warning text-warning" : "text-muted-foreground/40")} />
                  </button>
                ))}
              </div>
            </fieldset>
            <FormField id="rv-comment" label={t("review.commentLabel")}>
              <Textarea id="rv-comment" rows={5} maxLength={2000} placeholder={t("review.commentPlaceholder")} value={comment} onChange={(e) => setComment(e.target.value)} />
            </FormField>
            <FormField id="rv-name" label={t("review.nameLabel")} hint={t("review.nameHint")}>
              <Input id="rv-name" maxLength={60} autoComplete="given-name" value={name} onChange={(e) => setName(e.target.value)} />
            </FormField>
            <label className="flex items-start gap-2 text-sm">
              <Checkbox className="mt-0.5" checked={consent} onCheckedChange={(v) => setConsent(v === true)} />
              <span>{t("review.consent")}</span>
            </label>
            {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
            <Button type="submit" size="lg" disabled={busy}>{busy ? t("common.saving") : t("review.submit")}</Button>
            <p className="text-xs text-muted-foreground">{t("review.privacy")}</p>
          </form>
        )}
      </main>
    </div>
  );
}
