import { Link, Navigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useAuth } from "@/auth/AuthProvider";
import { usePageMeta } from "@/lib/seo";
import { Button } from "@/components/ui/button";
import { LanguageSwitcher } from "@/components/LanguageSwitcher";
import { Logo } from "@/components/Logo";

export function LandingPage() {
  const { t } = useTranslation();
  const { user } = useAuth();
  usePageMeta("Sanatorium OS", "CRM для санаториев и оздоровительных центров Казахстана");
  if (user?.email_confirmed_at) return <Navigate to="/select-org" replace />;

  return (
    <div className="flex min-h-screen flex-col">
      <header className="flex items-center justify-between px-4 py-4 sm:px-8">
        <Logo />
        <div className="flex items-center gap-2">
          <LanguageSwitcher />
          <Button asChild variant="ghost"><Link to="/login">{t("auth.login")}</Link></Button>
        </div>
      </header>
      <main className="mx-auto flex max-w-3xl flex-1 flex-col items-center justify-center px-4 text-center">
        <h1 className="text-3xl font-semibold tracking-tight sm:text-5xl">Sanatorium OS</h1>
        <p className="mt-4 max-w-xl text-muted-foreground">{t("auth.loginSubtitle")}</p>
        <div className="mt-8 flex flex-wrap justify-center gap-3">
          <Button asChild size="lg"><Link to="/register">{t("auth.registerLink")}</Link></Button>
          <Button asChild size="lg" variant="outline"><Link to="/login">{t("auth.login")}</Link></Button>
        </div>
      </main>
    </div>
  );
}
