import { useEffect } from "react";
import { useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { Clock, Mail, MapPin, MessageCircle, Phone } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { formatKzPhone, whatsappLink } from "@/lib/format";
import { usePageMeta } from "@/lib/seo";
import type { PublicSanatorium } from "@/lib/types";
import { hasSavedLanguage } from "@/i18n";
import { Button } from "@/components/ui/button";
import { LanguageSwitcher } from "@/components/LanguageSwitcher";
import { LoadingScreen } from "@/components/states/LoadingScreen";
import { ErrorState } from "@/components/states/ErrorState";
import { PublicBookingSection } from "@/features/bookings/PublicBookingSection";

/**
 * /s/:slug — публичная страница санатория. Данные приходят из get_public_sanatorium():
 * только опубликованные санатории и только безопасные поля (без БИН и внутренних данных CRM).
 */
export function PublicSanatoriumPage() {
  const { slug = "" } = useParams();
  const { t, i18n } = useTranslation();
  const query = useQuery({
    queryKey: ["public-sanatorium", slug],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_public_sanatorium", { p_slug: slug });
      if (error) throw error;
      return ((data ?? []) as PublicSanatorium[])[0] ?? null;
    },
  });
  const s = query.data;

  useEffect(() => {
    if (s && !hasSavedLanguage() && i18n.language !== s.default_language) void i18n.changeLanguage(s.default_language);
  }, [s, i18n]);

  usePageMeta(
    s ? `${s.name}${s.city ? ` — ${s.city}` : ""}` : t("public.notFoundTitle"),
    s ? (s.description ?? s.name).slice(0, 160) : undefined,
  );

  if (query.isLoading) return <LoadingScreen />;
  if (query.error) return <ErrorState error={query.error} onRetry={() => query.refetch()} />;
  if (!s) {
    return (
      <div className="mx-auto max-w-md px-4 py-24 text-center">
        <h1 className="text-xl font-semibold">{t("public.notFoundTitle")}</h1>
        <p className="mt-2 text-sm text-muted-foreground">{t("public.notFoundText")}</p>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-background">
      <header className="border-b bg-card">
        <div className="mx-auto flex max-w-5xl items-center justify-between gap-4 px-4 py-3">
          <span className="truncate font-semibold">{s.name}</span>
          <LanguageSwitcher />
        </div>
      </header>

      <section className="border-b bg-gradient-to-b from-accent to-background">
        <div className="mx-auto max-w-5xl px-4 py-12 sm:py-16">
          {s.city && <p className="text-sm font-medium text-primary">{s.city}</p>}
          <h1 className="mt-1 text-3xl font-semibold tracking-tight sm:text-4xl">{s.name}</h1>
          <div className="mt-6 flex flex-wrap gap-3">
            {s.whatsapp_phone && (
              <Button asChild size="lg">
                <a href={whatsappLink(s.whatsapp_phone, t("public.whatsappGreeting", { name: s.name }))} target="_blank" rel="noopener noreferrer">
                  <MessageCircle /> {t("public.writeWhatsapp")}
                </a>
              </Button>
            )}
            {s.phone && (
              <Button asChild size="lg" variant="outline">
                <a href={`tel:${s.phone}`}><Phone /> {t("public.call")}</a>
              </Button>
            )}
          </div>
        </div>
      </section>

      <main className="mx-auto grid max-w-5xl gap-8 px-4 py-10 md:grid-cols-[1fr_300px]">
        <div>
          {s.description && (
            <>
              <h2 className="text-lg font-semibold">{t("public.about")}</h2>
              <p className="mt-3 whitespace-pre-line text-sm leading-relaxed text-foreground/90">{s.description}</p>
            </>
          )}
          <PublicBookingSection slug={s.slug} />
        </div>
        <aside className="h-fit rounded-lg border bg-card p-5">
          <h2 className="font-semibold">{t("public.contacts")}</h2>
          <ul className="mt-3 grid gap-3 text-sm">
            {(s.address || s.city) && (
              <li className="flex gap-2"><MapPin className="mt-0.5 h-4 w-4 shrink-0 text-primary" />{[s.city, s.address].filter(Boolean).join(", ")}</li>
            )}
            {s.phone && (
              <li className="flex gap-2"><Phone className="mt-0.5 h-4 w-4 shrink-0 text-primary" /><a href={`tel:${s.phone}`} className="hover:underline">{formatKzPhone(s.phone)}</a></li>
            )}
            {s.email && (
              <li className="flex gap-2"><Mail className="mt-0.5 h-4 w-4 shrink-0 text-primary" /><a href={`mailto:${s.email}`} className="break-all hover:underline">{s.email}</a></li>
            )}
            {s.check_in_time && s.check_out_time && (
              <li className="flex gap-2"><Clock className="mt-0.5 h-4 w-4 shrink-0 text-primary" />{s.check_in_time} / {s.check_out_time}</li>
            )}
          </ul>
        </aside>
      </main>
      <footer className="border-t py-6 text-center text-xs text-muted-foreground">{t("public.poweredBy")}</footer>
    </div>
  );
}
