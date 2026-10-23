import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Link, Navigate, useLocation, useNavigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import type { z } from "zod";
import { supabase } from "@/lib/supabase";
import { loginSchema } from "@/lib/schemas";
import { describeError } from "@/lib/errors";
import { useAuth } from "@/auth/AuthProvider";
import { AuthLayout } from "@/layouts/AuthLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";

type Values = z.infer<typeof loginSchema>;

export function LoginPage() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const from = (location.state as { from?: string } | null)?.from ?? "/select-org";
  const [formError, setFormError] = useState<string | null>(null);
  const { register, handleSubmit, formState, getValues } = useForm<Values>({ resolver: zodResolver(loginSchema) });

  if (user?.email_confirmed_at) return <Navigate to={from} replace />;

  const onSubmit = handleSubmit(async (values) => {
    setFormError(null);
    const { error } = await supabase.auth.signInWithPassword(values);
    if (error) {
      if (/email not confirmed/i.test(error.message)) {
        navigate("/verify-email", { state: { email: values.email, notConfirmed: true } });
        return;
      }
      setFormError(describeError(error, t));
      return;
    }
    navigate(from, { replace: true });
  });

  const err = (key?: string) => (key ? t(key) : undefined);

  return (
    <AuthLayout
      title={t("auth.loginTitle")}
      subtitle={t("auth.loginSubtitle")}
      footer={<>{t("auth.noAccount")} <Link className="font-medium text-primary hover:underline" to="/register">{t("auth.registerLink")}</Link></>}
    >
      <form onSubmit={onSubmit} className="grid gap-4" noValidate>
        <FormField id="email" label={t("auth.email")} error={err(formState.errors.email?.message)}>
          <Input id="email" type="email" autoComplete="email" aria-invalid={!!formState.errors.email} {...register("email")} />
        </FormField>
        <FormField id="password" label={t("auth.password")} error={err(formState.errors.password?.message)}>
          <Input id="password" type="password" autoComplete="current-password" aria-invalid={!!formState.errors.password} {...register("password")} />
        </FormField>
        {formError && <p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{formError}</p>}
        <Button type="submit" disabled={formState.isSubmitting}>{formState.isSubmitting ? t("common.loading") : t("auth.login")}</Button>
        <Link
          to="/forgot-password"
          state={{ email: getValues("email") }}
          className="text-center text-sm text-muted-foreground hover:text-foreground"
        >
          {t("auth.forgotLink")}
        </Link>
      </form>
    </AuthLayout>
  );
}
