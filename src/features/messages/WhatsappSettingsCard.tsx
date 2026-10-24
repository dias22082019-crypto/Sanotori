import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Copy, ExternalLink } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { formatDateTime, type AppLanguage } from "@/lib/format";
import { copyText, describeWhatsappError, invokeWhatsapp, webhookUrl, type WhatsappSettings } from "@/lib/whatsapp";
import { useOrg } from "@/auth/OrgProvider";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { FormField } from "@/components/ui/form-field";
import { Skeleton } from "@/components/ui/skeleton";

/**
 * Подключение WhatsApp Cloud API. Токен и App Secret уходят в базу (Supabase Vault) и обратно не возвращаются:
 * поля пароля всегда пустые, пустое значение означает «оставить прежний».
 */
export function WhatsappSettingsCard() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can, writable, hasFeature } = useOrg();
  const qc = useQueryClient();
  const enabled = hasFeature("integrations");
  const editable = can("settings.manage") && writable && enabled;

  const settings = useQuery({
    queryKey: ["whatsapp-settings", org.id],
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("whatsapp_settings", { p_tenant: org.id });
      if (error) throw error;
      return data as WhatsappSettings;
    },
  });

  const s = settings.data;
  const [phoneId, setPhoneId] = useState("");
  const [wabaId, setWabaId] = useState("");
  const [token, setToken] = useState("");
  const [appSecret, setAppSecret] = useState("");
  const [isEnabled, setIsEnabled] = useState(true);
  const [busy, setBusy] = useState<"save" | "check" | "disconnect" | null>(null);

  useEffect(() => {
    if (!s) return;
    setPhoneId(s.phone_number_id ?? "");
    setWabaId(s.waba_id ?? "");
    setIsEnabled(s.is_enabled ?? true);
  }, [s]);

  const fail = (error: unknown) => toast.error(describeWhatsappError(error, t) ?? describeError(error, t));
  const refresh = () => qc.invalidateQueries({ queryKey: ["whatsapp-settings", org.id] });

  const save = async () => {
    if (!/^\d{5,25}$/.test(phoneId.trim()) || (wabaId.trim() !== "" && !/^\d{5,25}$/.test(wabaId.trim()))) {
      return toast.error(t("whatsapp.errors.ids"));
    }
    if (!s?.connected && token.trim() === "") return toast.error(t("whatsapp.errors.tokenRequired"));
    setBusy("save");
    const { error } = await supabase.rpc("save_whatsapp_settings", {
      p_tenant: org.id, p_phone_number_id: phoneId.trim(), p_waba_id: wabaId.trim() || null,
      p_access_token: token.trim() || null, p_app_secret: appSecret.trim() || null, p_enabled: isEnabled,
    });
    setBusy(null);
    if (error) return fail(error);
    setToken("");
    setAppSecret("");
    await refresh();
    toast.success(t("common.saved"));
  };

  const check = async () => {
    setBusy("check");
    try {
      const res = await invokeWhatsapp<{ ok: boolean; error?: string; display_phone?: string }>({ action: "check", tenant: org.id });
      if (res.ok) toast.success(t("whatsapp.checkOk", { phone: res.display_phone }));
      else toast.error(t("whatsapp.checkFailed", { error: describeWhatsappError({ message: res.error }, t) ?? res.error }));
    } catch (error) {
      fail(error);
    } finally {
      setBusy(null);
      await refresh();
    }
  };

  const disconnect = async () => {
    if (!window.confirm(t("whatsapp.disconnectConfirm"))) return;
    setBusy("disconnect");
    const { error } = await supabase.rpc("disconnect_whatsapp", { p_tenant: org.id });
    setBusy(null);
    if (error) return fail(error);
    setPhoneId("");
    setWabaId("");
    await refresh();
    toast.success(t("whatsapp.disconnected"));
  };

  const copy = async (text: string) => (await copyText(text) ? toast.success(t("common.copied")) : toast.error(t("marketing.copyFailed")));

  return (
    <Card className="mt-4">
      <CardHeader>
        <div className="flex flex-wrap items-center gap-2">
          <CardTitle>{t("whatsapp.title")}</CardTitle>
          {s?.connected && (
            <Badge variant={s.status === "ok" ? "success" : s.status === "error" ? "destructive" : "secondary"}>
              {t(`whatsapp.status.${s.status ?? "not_checked"}`)}
            </Badge>
          )}
          {s?.connected && !s.is_enabled && <Badge variant="warning">{t("whatsapp.paused")}</Badge>}
        </div>
        <CardDescription>{t("whatsapp.hint")}</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        {!enabled && <p className="rounded-md border border-warning/40 bg-warning/5 px-3 py-2 text-sm">{t("whatsapp.planNote")}</p>}

        {settings.isLoading ? (
          <Skeleton className="h-24" />
        ) : settings.error ? (
          <p className="text-sm text-destructive">{describeWhatsappError(settings.error, t) ?? describeError(settings.error, t)}</p>
        ) : (
          <>
            {s?.connected && (
              <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
                <dt className="text-muted-foreground">{t("whatsapp.number")}</dt>
                <dd>{s.display_phone ?? "—"}{s.verified_name ? ` · ${s.verified_name}` : ""}</dd>
                {s.checked_at && (<><dt className="text-muted-foreground">{t("whatsapp.checkedAt")}</dt><dd>{formatDateTime(s.checked_at, lang, org.timezone)}</dd></>)}
                {s.status === "error" && s.last_error && (<><dt className="text-muted-foreground">{t("whatsapp.lastError")}</dt><dd className="break-words text-destructive">{s.last_error}</dd></>)}
              </dl>
            )}

            <fieldset disabled={!editable || busy !== null} className="grid gap-4 sm:grid-cols-2">
              <FormField id="wa_phone_id" label={t("whatsapp.phoneNumberId")} hint={t("whatsapp.phoneNumberIdHint")}>
                <Input id="wa_phone_id" inputMode="numeric" autoComplete="off" value={phoneId} onChange={(e) => setPhoneId(e.target.value)} />
              </FormField>
              <FormField id="wa_waba_id" label={t("whatsapp.wabaId")} hint={t("whatsapp.optional")}>
                <Input id="wa_waba_id" inputMode="numeric" autoComplete="off" value={wabaId} onChange={(e) => setWabaId(e.target.value)} />
              </FormField>
              <FormField id="wa_token" label={t("whatsapp.accessToken")}
                hint={s?.has_token ? t("whatsapp.secretKept") : t("whatsapp.accessTokenHint")}>
                <Input id="wa_token" type="password" autoComplete="new-password" value={token} onChange={(e) => setToken(e.target.value)} />
              </FormField>
              <FormField id="wa_secret" label={t("whatsapp.appSecret")}
                hint={s?.has_app_secret ? t("whatsapp.secretKept") : t("whatsapp.appSecretHint")}>
                <Input id="wa_secret" type="password" autoComplete="new-password" value={appSecret} onChange={(e) => setAppSecret(e.target.value)} />
              </FormField>
              <label className="flex items-center gap-2 text-sm sm:col-span-2">
                <Checkbox checked={isEnabled} onCheckedChange={(v) => setIsEnabled(v === true)} />
                {t("whatsapp.enabled")}
              </label>
            </fieldset>

            {editable && (
              <div className="flex flex-wrap justify-end gap-2">
                {s?.connected && (
                  <Button variant="outline" className="text-destructive" disabled={busy !== null} onClick={disconnect}>
                    {t("whatsapp.disconnect")}
                  </Button>
                )}
                {s?.connected && s.has_token && (
                  <Button variant="outline" disabled={busy !== null} onClick={check}>
                    {busy === "check" ? t("whatsapp.checking") : t("whatsapp.check")}
                  </Button>
                )}
                <Button disabled={busy !== null} onClick={save}>{busy === "save" ? t("common.saving") : t("common.save")}</Button>
              </div>
            )}

            {s?.connected && s.verify_token && (
              <div className="grid gap-3 rounded-md border bg-muted/30 p-3 text-sm">
                <p className="font-medium">{t("whatsapp.webhookTitle")}</p>
                <CopyRow label={t("whatsapp.webhookUrl")} value={webhookUrl()} onCopy={copy} />
                <CopyRow label={t("whatsapp.verifyToken")} value={s.verify_token} onCopy={copy} />
                <p className="text-xs text-muted-foreground">{t("whatsapp.webhookHint")}</p>
                {!s.has_app_secret && <p className="text-xs text-warning">{t("whatsapp.noAppSecret")}</p>}
              </div>
            )}

            <details className="text-sm">
              <summary className="cursor-pointer text-primary">{t("whatsapp.howTo")}</summary>
              <ol className="mt-2 list-decimal space-y-1 pl-5 text-muted-foreground">
                {(t("whatsapp.steps", { returnObjects: true }) as string[]).map((step, i) => <li key={i}>{step}</li>)}
              </ol>
              <a className="mt-2 inline-flex items-center gap-1 text-primary hover:underline" target="_blank" rel="noopener noreferrer"
                href="https://developers.facebook.com/docs/whatsapp/cloud-api/get-started">
                {t("whatsapp.metaDocs")} <ExternalLink className="h-3.5 w-3.5" />
              </a>
            </details>
          </>
        )}
      </CardContent>
    </Card>
  );
}

function CopyRow({ label, value, onCopy }: { label: string; value: string; onCopy: (v: string) => void }) {
  const { t } = useTranslation();
  return (
    <div className="grid gap-1">
      <span className="text-xs text-muted-foreground">{label}</span>
      <div className="flex min-w-0 items-center gap-2">
        <code className="min-w-0 flex-1 truncate rounded bg-card px-2 py-1 text-xs">{value}</code>
        <Button size="icon" variant="ghost" className="h-7 w-7 shrink-0" aria-label={t("common.copy")} onClick={() => onCopy(value)}><Copy /></Button>
      </div>
    </div>
  );
}
