import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Link, useLocation } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { z } from "zod";
import { supabase } from "@/lib/supabase";
import { emailSchema } from "@/lib/schemas";
import { describeError } from "@/lib/errors";
import { AuthLayout } from "@/layouts/AuthLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { appUrl } from "@/lib/utils";
import { FormField } from "@/components/ui/form-field";

const schema = z.object({ email: emailSchema });

export function ForgotPasswordPage() {
  const { t } = useTranslation();
  const initialEmail = ((useLocation().state ?? {}) as { email?: string }).email ?? "";
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);
  const { register, handleSubmit, formState } = useForm<z.infer<typeof schema>>({
    resolver: zodResolver(schema),
    defaultValues: { email: initialEmail },
  });

  const onSubmit = handleSubmit(async ({ email }) => {
    const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: appUrl("/reset-password") });
    // Одинаковый ответ для существующих и несуществующих адресов: не раскрываем, кто зарегистрирован
    setResult(error && error.status === 429 ? { ok: false, text: describeError(error, t) } : { ok: true, text: t("auth.forgotSent") });
  });

  return (
    <AuthLayout
      title={t("auth.forgotTitle")}
      subtitle={t("auth.forgotSubtitle")}
      footer={<Link className="text-primary hover:underline" to="/login">{t("common.back")}</Link>}
    >
      <form onSubmit={onSubmit} className="grid gap-4" noValidate>
        <FormField id="email" label={t("auth.email")} error={formState.errors.email?.message ? t(formState.errors.email.message) : undefined}>
          <Input id="email" type="email" autoComplete="email" {...register("email")} />
        </FormField>
        {result && <p role="status" className={result.ok ? "text-sm text-success" : "text-sm text-destructive"}>{result.text}</p>}
        <Button type="submit" disabled={formState.isSubmitting}>{t("auth.forgotSubmit")}</Button>
      </form>
    </AuthLayout>
  );
}
