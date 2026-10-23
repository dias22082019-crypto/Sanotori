import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Link, useNavigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { z } from "zod";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { optionalKzPhone } from "@/lib/schemas";
import { describeError } from "@/lib/errors";
import { formatKzPhone } from "@/lib/format";
import { useAuth } from "@/auth/AuthProvider";
import { AuthLayout } from "@/layouts/AuthLayout";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { ConfirmDialog } from "@/components/ui/sheet";
import { LoadingScreen } from "@/components/states/LoadingScreen";
import { ErrorState } from "@/components/states/ErrorState";

const schema = z.object({
  full_name: z.string().trim().max(200, "validation.tooLong"),
  phone: optionalKzPhone,
  preferred_language: z.enum(["ru", "kk"]),
});

export function AccountPage() {
  const { t, i18n } = useTranslation();
  const { user, signOut } = useAuth();
  const navigate = useNavigate();
  const [confirmAll, setConfirmAll] = useState(false);
  const profile = useQuery({
    queryKey: ["profile", user?.id],
    queryFn: async () => {
      const { data, error } = await supabase.from("user_profiles").select("full_name, phone, preferred_language").eq("id", user!.id).single();
      if (error) throw error;
      return data as { full_name: string | null; phone: string | null; preferred_language: "ru" | "kk" };
    },
  });
  const { register, handleSubmit, formState, reset } = useForm<z.input<typeof schema>, unknown, z.output<typeof schema>>({
    resolver: zodResolver(schema),
  });

  useEffect(() => {
    if (profile.data)
      reset({
        full_name: profile.data.full_name ?? "",
        phone: profile.data.phone ? formatKzPhone(profile.data.phone) : "",
        preferred_language: profile.data.preferred_language,
      });
  }, [profile.data, reset]);

  if (profile.isLoading) return <LoadingScreen />;
  if (profile.error) return <ErrorState error={profile.error} onRetry={() => profile.refetch()} />;

  const onSubmit = handleSubmit(async (values) => {
    const { error } = await supabase.from("user_profiles").update(values).eq("id", user!.id);
    if (error) {
      toast.error(describeError(error, t));
      return;
    }
    await i18n.changeLanguage(values.preferred_language);
    toast.success(t("common.saved"));
  });

  const err = (key?: string) => (key ? t(key) : undefined);

  return (
    <AuthLayout title={t("account.title")} subtitle={user?.email} footer={<Link className="text-primary hover:underline" to="/select-org">{t("common.back")}</Link>}>
      <form onSubmit={onSubmit} className="grid gap-4" noValidate>
        <FormField id="full_name" label={t("account.fullName")} error={err(formState.errors.full_name?.message)}>
          <Input id="full_name" autoComplete="name" {...register("full_name")} />
        </FormField>
        <FormField id="phone" label={t("account.phone")} error={err(formState.errors.phone?.message)}>
          <Input id="phone" type="tel" inputMode="tel" placeholder="+7 7XX XXX XX XX" {...register("phone")} />
        </FormField>
        <FormField id="preferred_language" label={t("account.language")}>
          <NativeSelect id="preferred_language" {...register("preferred_language")}>
            <option value="ru">{t("common.languages.ru")}</option>
            <option value="kk">{t("common.languages.kk")}</option>
          </NativeSelect>
        </FormField>
        <Button type="submit" disabled={formState.isSubmitting}>{t("common.save")}</Button>
      </form>

      <div className="mt-6 grid gap-2 border-t pt-4">
        <p className="text-sm font-medium">{t("account.sessions")}</p>
        <Button variant="outline" onClick={async () => { await signOut("local"); navigate("/login", { replace: true }); }}>
          {t("account.signOutHere")}
        </Button>
        <Button variant="outline" className="text-destructive" onClick={() => setConfirmAll(true)}>{t("account.signOutAll")}</Button>
      </div>
      <ConfirmDialog
        open={confirmAll}
        onOpenChange={setConfirmAll}
        title={t("account.signOutAll")}
        description={t("account.signOutAllHint")}
        confirmLabel={t("common.confirm")}
        cancelLabel={t("common.cancel")}
        destructive
        onConfirm={async () => {
          await signOut("global");
          navigate("/login", { replace: true });
        }}
      />
    </AuthLayout>
  );
}
