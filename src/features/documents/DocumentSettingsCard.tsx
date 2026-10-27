import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { useOrg } from "@/auth/OrgProvider";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, Textarea } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";

const FIELDS = ["legal_address", "bank_name", "iik", "bik", "director_name", "vat_rate", "contract_terms"] as const;
type Field = (typeof FIELDS)[number];

/** Проверка реквизитов до отправки; окончательно проверяет база (ограничения колонок) */
export function validateRequisites(v: Record<Field, string>): Partial<Record<Field, string>> {
  const errors: Partial<Record<Field, string>> = {};
  const iik = v.iik.replace(/\s/g, "").toUpperCase();
  if (iik && !/^KZ[0-9A-Z]{18}$/.test(iik)) errors.iik = "documents.settings.iikInvalid";
  const bik = v.bik.trim().toUpperCase();
  if (bik && !/^[A-Z0-9]{8}$/.test(bik)) errors.bik = "documents.settings.bikInvalid";
  const rate = v.vat_rate.trim().replace(",", ".");
  if (rate && !(Number(rate) > 0 && Number(rate) <= 30)) errors.vat_rate = "documents.settings.vatInvalid";
  return errors;
}

/** Реквизиты для договора, счёта и акта. Отдельная форма: до обновления 0015 этих колонок нет. */
export function DocumentSettingsCard() {
  const { t } = useTranslation();
  const { org, can, writable } = useOrg();
  const qc = useQueryClient();
  const ready = "iik" in org;
  const editable = can("settings.manage") && writable && ready;
  const [v, setV] = useState<Record<Field, string>>(() => ({
    legal_address: org.legal_address ?? "", bank_name: org.bank_name ?? "", iik: org.iik ?? "", bik: org.bik ?? "",
    director_name: org.director_name ?? "", vat_rate: org.vat_rate ? String(org.vat_rate) : "", contract_terms: org.contract_terms ?? "",
  }));
  const [errors, setErrors] = useState<Partial<Record<Field, string>>>({});
  const [busy, setBusy] = useState(false);

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    const found = validateRequisites(v);
    setErrors(found);
    if (Object.keys(found).length) return;
    const text = (x: string) => x.trim() || null;
    setBusy(true);
    const { error, data } = await supabase.from("organizations").update({
      legal_address: text(v.legal_address), bank_name: text(v.bank_name),
      iik: text(v.iik.replace(/\s/g, "").toUpperCase()), bik: text(v.bik.toUpperCase()),
      director_name: text(v.director_name), vat_rate: v.vat_rate.trim() ? Number(v.vat_rate.replace(",", ".")) : null,
      contract_terms: text(v.contract_terms),
    }).eq("id", org.id).select("id");
    setBusy(false);
    if (error || !data?.length) return toast.error(describeError(error ?? { code: "42501" }, t));
    await qc.invalidateQueries({ queryKey: ["org", org.id] });
    toast.success(t("common.saved"));
  };

  const field = (f: Field, props: { label: string; hint?: string; className?: string; mono?: boolean; maxLength?: number; inputMode?: "decimal" }) => (
    <FormField id={`doc-${f}`} label={props.label} hint={props.hint} error={errors[f] ? t(errors[f]!) : undefined} className={props.className}>
      <Input id={`doc-${f}`} value={v[f]} readOnly={!editable} maxLength={props.maxLength} inputMode={props.inputMode}
        className={props.mono ? "font-mono" : undefined} onChange={(e) => setV({ ...v, [f]: e.target.value })} />
    </FormField>
  );

  return (
    <Card className="mt-4">
      <CardHeader>
        <CardTitle>{t("documents.settings.title")}</CardTitle>
        <CardDescription>{t("documents.settings.hint")}</CardDescription>
      </CardHeader>
      <CardContent>
        {!ready && <p className="mb-3 text-xs text-warning">{t("documents.settings.needsUpdate")}</p>}
        <form onSubmit={save} className="grid gap-4 sm:grid-cols-2" noValidate>
          {field("legal_address", { label: t("documents.settings.legalAddress"), className: "sm:col-span-2", maxLength: 300 })}
          {field("bank_name", { label: t("documents.settings.bank"), maxLength: 200 })}
          {field("director_name", { label: t("documents.settings.director"), hint: t("documents.settings.directorHint"), maxLength: 200 })}
          {field("iik", { label: t("documents.settings.iik"), hint: "KZ…", mono: true, maxLength: 24 })}
          {field("bik", { label: t("documents.settings.bik"), mono: true, maxLength: 8 })}
          {field("vat_rate", { label: t("documents.settings.vat"), hint: t("documents.settings.vatHint"), inputMode: "decimal", maxLength: 5 })}
          <FormField id="doc-contract_terms" label={t("documents.settings.terms")} hint={t("documents.settings.termsHint")} className="sm:col-span-2">
            <Textarea id="doc-contract_terms" rows={6} maxLength={20000} value={v.contract_terms} readOnly={!editable}
              placeholder={t("documents.contract.defaultTerms")}
              onChange={(e) => setV({ ...v, contract_terms: e.target.value })} />
          </FormField>
          {editable && (
            <div className="flex justify-end sm:col-span-2">
              <Button type="submit" disabled={busy}>{busy ? t("common.saving") : t("common.save")}</Button>
            </div>
          )}
        </form>
      </CardContent>
    </Card>
  );
}
