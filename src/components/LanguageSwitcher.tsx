import { useTranslation } from "react-i18next";
import { cn } from "@/lib/utils";
import { SUPPORTED_LANGUAGES } from "@/i18n";

/** Переключатель RU / KK */
export function LanguageSwitcher({ className }: { className?: string }) {
  const { i18n, t } = useTranslation();
  return (
    <div role="group" aria-label={t("common.language")} className={cn("inline-flex rounded-md border bg-card p-0.5", className)}>
      {SUPPORTED_LANGUAGES.map((lng) => (
        <button
          key={lng}
          type="button"
          onClick={() => void i18n.changeLanguage(lng)}
          aria-pressed={i18n.language === lng}
          title={t(`common.languages.${lng}`)}
          className={cn(
            "rounded px-2 py-1 text-xs font-medium uppercase transition-colors",
            i18n.language === lng ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground",
          )}
        >
          {lng === "kk" ? "ҚАЗ" : "РУС"}
        </button>
      ))}
    </div>
  );
}
