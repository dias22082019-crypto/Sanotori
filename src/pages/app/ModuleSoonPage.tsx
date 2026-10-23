import { useTranslation } from "react-i18next";
import { Hammer } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/states/EmptyState";

/** Честная заглушка: модуль ещё не реализован и ничего не сохраняет */
export function ModuleSoonPage({ moduleKey, stage }: { moduleKey: string; stage: number }) {
  const { t } = useTranslation();
  const module = t(`nav.${moduleKey}`);
  return (
    <>
      <PageHeader title={module} />
      <EmptyState icon={<Hammer className="h-5 w-5" />} title={t("common.moduleSoonTitle")} text={t("common.moduleSoonText", { module, stage })} />
    </>
  );
}
