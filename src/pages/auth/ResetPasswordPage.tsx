import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Link, useNavigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { z } from "zod";
import { supabase } from "@/lib/supabase";
import { passwordSchema } from "@/lib/schemas";
import { describeError } from "@/lib/errors";
import { useAuth } from "@/auth/AuthProvider";
import { AuthLayout } from "@/layouts/AuthLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { LoadingScreen } from "@/components/states/LoadingScreen";

const schema = z.object({ password: passwordSchema });

export function ResetPasswordPage() {
  const { t } = useTranslation();
  const { session, loading } = useAuth();
  const navigate = useNavigate();
  const [formError, setFormError] = useState<string | null>(null);
  const { register, handleSubmit, formState } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema) });

  if (loading) return <LoadingScreen />;
  if (!session) {
    return (
      <AuthLayout title={t("auth.resetTitle")} footer={<Link className="text-primary hover:underline" to="/forgot-password">{t("auth.forgotSubmit")}</Link>}>
        <p className="text-sm text-muted-foreground">{t("auth.resetInvalid")}</p>
      </AuthLayout>
    );
  }

  const onSubmit = handleSubmit(async ({ password }) => {
    setFormError(null);
    const { error } = await supabase.auth.updateUser({ password });
    if (error) {
      setFormError(describeError(error, t));
      return;
    }
    navigate("/select-org", { replace: true, state: { flash: t("auth.resetDone") } });
  });

  return (
    <AuthLayout title={t("auth.resetTitle")}>
      <form onSubmit={onSubmit} className="grid gap-4" noValidate>
        <FormField id="password" label={t("auth.newPassword")} hint={t("auth.passwordHint")}
          error={formState.errors.password?.message ? t(formState.errors.password.message) : undefined}>
          <Input id="password" type="password" autoComplete="new-password" {...register("password")} />
        </FormField>
        {formError && <p role="alert" className="text-sm text-destructive">{formError}</p>}
        <Button type="submit" disabled={formState.isSubmitting}>{t("auth.resetSubmit")}</Button>
      </form>
    </AuthLayout>
  );
}
