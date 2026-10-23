import { Controller, useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import type { z } from "zod";
import { supabase } from "@/lib/supabase";
import { organizationSettingsSchema, type OrganizationSettingsInput } from "@/lib/schemas";
import { describeError } from "@/lib/errors";
import { formatKzPhone } from "@/lib/format";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect, Textarea } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { appUrl } from "@/lib/utils";
import { FormField } from "@/components/ui/form-field";

type Output = z.output<typeof organizationSettingsSchema>;

const TIMEZONES = ["Asia/Almaty", "Asia/Qostanay", "Asia/Qyzylorda", "Asia/Aqtobe", "Asia/Aqtau", "Asia/Atyrau", "Asia/Oral"];

/** Настройки санатория. Сохранение проверяет сервер: RLS (settings.manage) и ограничения таблицы. */
export function SettingsPage() {
  const { t } = useTranslation();
  const { org, can, writable } = useOrg();
  const queryClient = useQueryClient();
  const editable = can("settings.manage") && writable;

  const { register, control, handleSubmit, formState, watch } = useForm<OrganizationSettingsInput, unknown, Output>({
    resolver: zodResolver(organizationSettingsSchema),
    defaultValues: {
      name: org.name,
      description: org.description ?? "",
      address: org.address ?? "",
      city: org.city ?? "",
      phone: org.phone ? formatKzPhone(org.phone) : "",
      email: org.email ?? "",
      whatsapp_phone: org.whatsapp_phone ? formatKzPhone(org.whatsapp_phone) : "",
      legal_name: org.legal_name ?? "",
      bin: org.bin ?? "",
      timezone: org.timezone,
      default_language: org.default_language,
      is_published: org.is_published,
    },
  });

  const onSubmit = handleSubmit(async (values) => {
    const { error, data } = await supabase.from("organizations").update(values).eq("id", org.id).select("id");
    if (error || !data?.length) {
      toast.error(describeError(error ?? { code: "42501" }, t));
      return;
    }
    await queryClient.invalidateQueries({ queryKey: ["org", org.id] });
    toast.success(t("common.saved"));
  });

  const err = (key?: string) => (key ? t(key) : undefined);
  const e = formState.errors;

  return (
    <>
      <PageHeader title={t("settings.title")} description={!editable ? t("settings.readOnlyHint") : undefined} />
      <form onSubmit={onSubmit} noValidate>
        <fieldset disabled={!editable || formState.isSubmitting} className="grid gap-4">
          <Card>
            <CardHeader><CardTitle>{t("settings.profileSection")}</CardTitle></CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              <FormField id="name" label={t("settings.name")} error={err(e.name?.message)} className="sm:col-span-2">
                <Input id="name" {...register("name")} />
              </FormField>
              <FormField id="description" label={t("settings.description")} error={err(e.description?.message)} className="sm:col-span-2">
                <Textarea id="description" rows={4} {...register("description")} />
              </FormField>
              <FormField id="timezone" label={t("settings.timezone")}>
                <NativeSelect id="timezone" {...register("timezone")}>
                  {TIMEZONES.map((tz) => <option key={tz} value={tz}>{tz}</option>)}
                </NativeSelect>
              </FormField>
              <FormField id="default_language" label={t("settings.language")}>
                <NativeSelect id="default_language" {...register("default_language")}>
                  <option value="ru">{t("common.languages.ru")}</option>
                  <option value="kk">{t("common.languages.kk")}</option>
                </NativeSelect>
              </FormField>
              <FormField id="currency" label={t("settings.currency")}>
                <Input id="currency" value="KZT, ₸" readOnly disabled />
              </FormField>
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>{t("settings.contactsSection")}</CardTitle></CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              <FormField id="city" label={t("settings.city")} error={err(e.city?.message)}>
                <Input id="city" {...register("city")} />
              </FormField>
              <FormField id="address" label={t("settings.address")} error={err(e.address?.message)}>
                <Input id="address" {...register("address")} />
              </FormField>
              <FormField id="phone" label={t("settings.phone")} error={err(e.phone?.message)}>
                <Input id="phone" type="tel" inputMode="tel" placeholder="+7 7XX XXX XX XX" {...register("phone")} />
              </FormField>
              <FormField id="whatsapp_phone" label={t("settings.whatsapp")} error={err(e.whatsapp_phone?.message)}>
                <Input id="whatsapp_phone" type="tel" inputMode="tel" placeholder="+7 7XX XXX XX XX" {...register("whatsapp_phone")} />
              </FormField>
              <FormField id="email" label={t("settings.email")} error={err(e.email?.message)}>
                <Input id="email" type="email" {...register("email")} />
              </FormField>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>{t("settings.legalSection")}</CardTitle>
              <CardDescription>{t("settings.legalHint")}</CardDescription>
            </CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              <FormField id="legal_name" label={t("settings.legalName")} error={err(e.legal_name?.message)}>
                <Input id="legal_name" {...register("legal_name")} />
              </FormField>
              <FormField id="bin" label={t("settings.bin")} error={err(e.bin?.message)}>
                <Input id="bin" inputMode="numeric" maxLength={12} {...register("bin")} />
              </FormField>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>{t("settings.publicSection")}</CardTitle>
              <CardDescription>{t("settings.isPublishedHint")}</CardDescription>
            </CardHeader>
            <CardContent>
              <label className="flex items-center gap-2 text-sm">
                <Controller control={control} name="is_published"
                  render={({ field }) => <Checkbox checked={field.value} onCheckedChange={(v) => field.onChange(v === true)} />} />
                {t("settings.isPublished", { slug: org.slug })}
              </label>
              {watch("is_published") && org.is_published && (
                <a className="mt-2 inline-block text-sm text-primary hover:underline" href={appUrl(`/s/${org.slug}`)} target="_blank" rel="noopener noreferrer">
                  /s/{org.slug}
                </a>
              )}
            </CardContent>
          </Card>

          {editable && (
            <div className="flex justify-end">
              <Button type="submit">{formState.isSubmitting ? t("common.saving") : t("common.save")}</Button>
            </div>
          )}
        </fieldset>
      </form>
    </>
  );
}
