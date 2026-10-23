import { useState } from "react";
import { Controller, useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Link, useNavigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import type { z } from "zod";
import { supabase } from "@/lib/supabase";
import { registerSchema } from "@/lib/schemas";
import { describeError } from "@/lib/errors";
import { AuthLayout } from "@/layouts/AuthLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { FormField } from "@/components/ui/form-field";

type Values = z.input<typeof registerSchema>;

export function RegisterPage() {
  const { t, i18n } = useTranslation();
  const navigate = useNavigate();
  const [formError, setFormError] = useState<string | null>(null);
  const { register, control, handleSubmit, formState } = useForm<Values>({
    resolver: zodResolver(registerSchema),
    defaultValues: { consent: false as unknown as true },
  });

  const onSubmit = handleSubmit(async (values) => {
    setFormError(null);
    const { error } = await supabase.auth.signUp({
      email: values.email,
      password: values.password,
      options: {
        emailRedirectTo: `${window.location.origin}/onboarding`,
        data: { full_name: values.fullName, preferred_language: i18n.language },
      },
    });
    if (error) {
      setFormError(describeError(error, t));
      return;
    }
    navigate("/verify-email", { state: { email: values.email } });
  });

  const err = (key?: string) => (key ? t(key) : undefined);

  return (
    <AuthLayout
      title={t("auth.registerTitle")}
      subtitle={t("auth.registerSubtitle")}
      footer={<>{t("auth.haveAccount")} <Link className="font-medium text-primary hover:underline" to="/login">{t("auth.login")}</Link></>}
    >
      <form onSubmit={onSubmit} className="grid gap-4" noValidate>
        <FormField id="fullName" label={t("auth.fullName")} error={err(formState.errors.fullName?.message)}>
          <Input id="fullName" autoComplete="name" {...register("fullName")} />
        </FormField>
        <FormField id="email" label={t("auth.email")} error={err(formState.errors.email?.message)}>
          <Input id="email" type="email" autoComplete="email" {...register("email")} />
        </FormField>
        <FormField id="password" label={t("auth.password")} hint={t("auth.passwordHint")} error={err(formState.errors.password?.message)}>
          <Input id="password" type="password" autoComplete="new-password" {...register("password")} />
        </FormField>
        <div className="grid gap-1.5">
          <label className="flex items-start gap-2 text-sm leading-snug">
            <Controller
              control={control}
              name="consent"
              render={({ field }) => (
                <Checkbox className="mt-0.5" checked={field.value === true} onCheckedChange={(v) => field.onChange(v === true)} />
              )}
            />
            <span>{t("auth.acceptTerms")}</span>
          </label>
          {formState.errors.consent && <p role="alert" className="text-xs text-destructive">{t(formState.errors.consent.message ?? "")}</p>}
        </div>
        {formError && <p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{formError}</p>}
        <Button type="submit" disabled={formState.isSubmitting}>{formState.isSubmitting ? t("common.loading") : t("auth.register")}</Button>
      </form>
    </AuthLayout>
  );
}
