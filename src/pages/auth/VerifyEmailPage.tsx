import { useState } from "react";
import { Link, useLocation } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { MailCheck } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { AuthLayout } from "@/layouts/AuthLayout";
import { appUrl } from "@/lib/utils";
import { Button } from "@/components/ui/button";

export function VerifyEmailPage() {
  const { t } = useTranslation();
  const state = (useLocation().state ?? {}) as { email?: string; notConfirmed?: boolean };
  const [status, setStatus] = useState<{ ok: boolean; text: string } | null>(null);
  const [sending, setSending] = useState(false);

  const resend = async () => {
    if (!state.email) return;
    setSending(true);
    const { error } = await supabase.auth.resend({
      type: "signup",
      email: state.email,
      options: { emailRedirectTo: appUrl("/onboarding") },
    });
    setSending(false);
    setStatus(error ? { ok: false, text: describeError(error, t) } : { ok: true, text: t("auth.resent") });
  };

  return (
    <AuthLayout title={t("auth.verifyTitle")} footer={<Link className="text-primary hover:underline" to="/login">{t("auth.login")}</Link>}>
      <div className="flex flex-col items-center gap-4 text-center">
        <MailCheck className="h-10 w-10 text-primary" />
        <p className="text-sm text-muted-foreground">
          {state.notConfirmed ? t("auth.verifyNotConfirmed") : t("auth.verifyText", { email: state.email ?? "" })}
        </p>
        {state.email && (
          <Button variant="outline" onClick={resend} disabled={sending}>{t("auth.resend")}</Button>
        )}
        {status && <p role="status" className={status.ok ? "text-sm text-success" : "text-sm text-destructive"}>{status.text}</p>}
      </div>
    </AuthLayout>
  );
}
