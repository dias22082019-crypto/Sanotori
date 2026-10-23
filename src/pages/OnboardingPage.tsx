import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useNavigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import type { z } from "zod";
import { supabase } from "@/lib/supabase";
import { organizationCreateSchema } from "@/lib/schemas";
import { describeError } from "@/lib/errors";
import { slugify } from "@/lib/format";
import { AuthLayout } from "@/layouts/AuthLayout";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";

type Values = z.infer<typeof organizationCreateSchema>;

/** Создание санатория владельцем после регистрации. Роль owner назначает сервер (create_organization). */
export function OnboardingPage() {
  const { t, i18n } = useTranslation();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [formError, setFormError] = useState<string | null>(null);
  const [slugEdited, setSlugEdited] = useState(false);
  const { register, handleSubmit, formState, setValue, watch, setError } = useForm<Values>({
    resolver: zodResolver(organizationCreateSchema),
    defaultValues: { name: "", slug: "", city: "", language: i18n.language === "kk" ? "kk" : "ru" },
  });
  const slug = watch("slug");

  const onSubmit = handleSubmit(async (values) => {
    setFormError(null);
    const { error } = await supabase.rpc("create_organization", {
      p_name: values.name,
      p_slug: values.slug,
      p_city: values.city || null,
      p_language: values.language,
    });
    if (error) {
      if (error.code === "23505") setError("slug", { message: "onboarding.slugTaken" });
      else if (error.code === "54000") setFormError(t("onboarding.limitReached"));
      else setFormError(describeError(error, t));
      return;
    }
    await queryClient.invalidateQueries({ queryKey: ["my-organizations"] });
    navigate(`/app/${values.slug}`, { replace: true });
  });

  const err = (key?: string) => (key ? t(key) : undefined);

  return (
    <AuthLayout title={t("onboarding.title")} subtitle={t("onboarding.subtitle")}>
      <form onSubmit={onSubmit} className="grid gap-4" noValidate>
        <FormField id="name" label={t("onboarding.name")} error={err(formState.errors.name?.message)}>
          <Input
            id="name"
            {...register("name", {
              onChange: (e) => {
                if (!slugEdited) setValue("slug", slugify(e.target.value));
              },
            })}
          />
        </FormField>
        <FormField id="slug" label={t("onboarding.slug")} error={err(formState.errors.slug?.message)}
          hint={t("onboarding.slugHint", { slug: slug || "…" })}>
          <Input id="slug" autoCapitalize="none" spellCheck={false} {...register("slug", { onChange: () => setSlugEdited(true) })} />
        </FormField>
        <FormField id="city" label={t("onboarding.city")} error={err(formState.errors.city?.message)}>
          <Input id="city" {...register("city")} />
        </FormField>
        <FormField id="language" label={t("onboarding.language")}>
          <NativeSelect id="language" {...register("language")}>
            <option value="ru">{t("common.languages.ru")}</option>
            <option value="kk">{t("common.languages.kk")}</option>
          </NativeSelect>
        </FormField>
        {formError && <p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{formError}</p>}
        <Button type="submit" disabled={formState.isSubmitting}>{formState.isSubmitting ? t("common.saving") : t("onboarding.submit")}</Button>
      </form>
    </AuthLayout>
  );
}
