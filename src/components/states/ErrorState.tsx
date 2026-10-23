import { AlertTriangle, Lock, SearchX } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/button";
import { describeError } from "@/lib/errors";

function StateBox(props: { icon: React.ReactNode; title: string; text: string; action?: React.ReactNode }) {
  return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-3 px-4 py-16 text-center">
      <div className="flex h-12 w-12 items-center justify-center rounded-full bg-muted text-muted-foreground">{props.icon}</div>
      <h2 className="text-lg font-semibold">{props.title}</h2>
      <p className="text-sm text-muted-foreground">{props.text}</p>
      {props.action}
    </div>
  );
}

export function ErrorState({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  const { t } = useTranslation();
  return (
    <StateBox
      icon={<AlertTriangle className="h-5 w-5" />}
      title={t("common.errorTitle")}
      text={describeError(error, t)}
      action={onRetry ? <Button variant="outline" onClick={onRetry}>{t("common.retry")}</Button> : undefined}
    />
  );
}

export function ForbiddenState() {
  const { t } = useTranslation();
  return <StateBox icon={<Lock className="h-5 w-5" />} title={t("common.forbiddenTitle")} text={t("common.forbiddenText")} />;
}

export function NotFoundState() {
  const { t } = useTranslation();
  return (
    <StateBox
      icon={<SearchX className="h-5 w-5" />}
      title={t("common.notFoundTitle")}
      text={t("common.notFoundText")}
      action={<Button asChild variant="outline"><Link to="/">{t("common.toHome")}</Link></Button>}
    />
  );
}
