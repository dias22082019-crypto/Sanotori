import { useEffect, useRef, useState } from "react";
import { Link, Navigate, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/auth/AuthProvider";
import { AuthLayout } from "@/layouts/AuthLayout";
import { Button } from "@/components/ui/button";
import { LoadingScreen } from "@/components/states/LoadingScreen";

type State = "pending" | "accepted" | "invalid" | "wrong-email" | "error";

/** /invite/:token — принятие приглашения. Сервер сверяет email из токена Supabase с адресом приглашения. */
export function AcceptInvitePage() {
  const { token = "" } = useParams();
  const { t } = useTranslation();
  const { user, loading } = useAuth();
  const queryClient = useQueryClient();
  const [state, setState] = useState<State>("pending");
  const started = useRef(false);

  useEffect(() => {
    if (!user?.email_confirmed_at || started.current) return;
    started.current = true;
    void supabase.rpc("accept_invitation", { p_token: token }).then(async ({ error }) => {
      if (!error) {
        await queryClient.invalidateQueries({ queryKey: ["my-organizations"] });
        setState("accepted");
      } else if (error.code === "P0002") setState("invalid");
      else if (error.code === "42501") setState("wrong-email");
      else setState("error");
    });
  }, [user, token, queryClient]);

  if (loading) return <LoadingScreen />;
  if (!user) return <Navigate to="/login" replace state={{ from: `/invite/${token}` }} />;

  const text: Record<State, string> = {
    pending: t("invite.accepting"),
    accepted: t("invite.accepted"),
    invalid: t("invite.invalid"),
    "wrong-email": t("invite.wrongEmail"),
    error: t("common.errorGeneric"),
  };

  return (
    <AuthLayout title={t("invite.title")}>
      <div className="grid gap-4 text-sm">
        <p role="status">{text[state]}</p>
        {state === "accepted" && <Button asChild><Link to="/select-org">{t("invite.open")}</Link></Button>}
      </div>
    </AuthLayout>
  );
}
