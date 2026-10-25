import { useState, type ReactNode } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { AlertTriangle, ArrowLeft, Printer } from "lucide-react";
import type { TFunction } from "i18next";
import { supabase } from "@/lib/supabase";
import { formatDate, formatKzPhone, formatKzt, formatNumber, todayInTimeZone, type AppLanguage } from "@/lib/format";
import { DOCUMENT_KINDS, amountInWords, describeDocumentError, vatIncluded, type BookingDocument } from "@/lib/documents";
import { ageOn, RECORD_FIELDS, type MedicalCard } from "@/lib/medical";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorState, NotFoundState } from "@/components/states/ErrorState";

/** Панель над листом (не печатается) и лист A4. Язык документа выбирается отдельно от языка интерфейса. */
function PrintShell({ back, lang, onLang, warning, children }: {
  back: string; lang: AppLanguage; onLang: (l: AppLanguage) => void; warning?: ReactNode; children: ReactNode;
}) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const goBack = () => (window.history.length > 1 ? navigate(-1) : navigate(back));
  return (
    <div className="min-h-screen bg-muted/60 print:bg-white">
      <div className="sticky top-0 z-10 border-b bg-card print:hidden">
        <div className="mx-auto flex max-w-[210mm] flex-wrap items-center gap-2 px-4 py-2">
          <Button variant="ghost" size="sm" onClick={goBack}><ArrowLeft /> {t("common.back")}</Button>
          <div role="group" aria-label={t("documents.language")} className="ml-auto inline-flex rounded-md border p-0.5 text-xs">
            {(["ru", "kk"] as const).map((l) => (
              <button key={l} type="button" aria-pressed={lang === l} onClick={() => onLang(l)}
                className={cn("rounded px-2 py-1", lang === l ? "bg-primary text-primary-foreground" : "text-muted-foreground")}>
                {t(`documents.lang.${l}`)}
              </button>
            ))}
          </div>
          <Button size="sm" onClick={() => window.print()}><Printer /> {t("documents.print")}</Button>
        </div>
        {warning && (
          <div className="mx-auto flex max-w-[210mm] items-start gap-2 px-4 pb-2 text-xs text-warning">
            <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" /><span>{warning}</span>
          </div>
        )}
      </div>
      <div className="overflow-x-auto px-2 py-4 sm:px-4 print:overflow-visible print:p-0">
        <article className="doc-sheet mx-auto w-[210mm] min-w-[210mm] bg-white p-[15mm] text-[11pt] leading-snug text-black shadow-sm print:w-auto print:min-w-0 print:p-0 print:shadow-none">
          {children}
        </article>
      </div>
    </div>
  );
}

function useDocLang() {
  const { i18n } = useTranslation();
  const [lang, setLang] = useState<AppLanguage>(i18n.language === "kk" ? "kk" : "ru");
  return { lang, setLang, dt: i18n.getFixedT(lang) };
}

function Loading() {
  return <div className="mx-auto max-w-[210mm] p-6"><Skeleton className="h-[60vh]" /></div>;
}

const money = (v: number, lang: AppLanguage) => formatKzt(v, lang);

// ---------------------------------------------------------------------------
// Договор, счёт, акт
// ---------------------------------------------------------------------------

export function BookingDocumentPage() {
  const { kind = "", bookingId = "" } = useParams();
  const { t } = useTranslation();
  const { org } = useOrg();
  const { lang, setLang, dt } = useDocLang();
  const valid = (DOCUMENT_KINDS as string[]).includes(kind);

  const doc = useQuery({
    queryKey: ["booking-document", bookingId, kind],
    enabled: valid,
    retry: false,
    refetchOnWindowFocus: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("booking_document", { p_booking_id: bookingId, p_kind: kind });
      if (error) throw error;
      return data as BookingDocument;
    },
  });

  const back = `/app/${org.slug}/bookings`;
  if (!valid) return <NotFoundState />;
  if (doc.isLoading) return <Loading />;
  if (doc.error) {
    return (
      <div className="mx-auto flex max-w-md flex-col items-center gap-3 px-4 py-16 text-center">
        <AlertTriangle className="h-6 w-6 text-muted-foreground" />
        <p className="text-sm">{describeDocumentError(doc.error, t)}</p>
        <Button asChild variant="outline"><Link to={back}>{t("common.back")}</Link></Button>
      </div>
    );
  }

  const d = doc.data!;
  const o = d.organization;
  const missing = [!o.legal_name && "legalName", !o.bin && "bin", kind !== "contract" && !o.iik && "iik", !o.director_name && "director"]
    .filter(Boolean) as string[];
  const warning = missing.length > 0 ? (
    <>
      {t("documents.missingRequisites", { fields: missing.map((f) => t(`documents.req.${f}`)).join(", ") })}{" "}
      <Link className="underline" to={`/app/${org.slug}/settings`}>{t("documents.toSettings")}</Link>
    </>
  ) : kind === "contract" && !o.contract_terms ? t("documents.defaultTermsNote") : undefined;

  return (
    <PrintShell back={back} lang={lang} onLang={setLang} warning={warning}>
      {kind === "contract" && <Contract d={d} lang={lang} dt={dt} />}
      {kind === "invoice" && <Invoice d={d} lang={lang} dt={dt} />}
      {kind === "act" && <Act d={d} lang={lang} dt={dt} />}
    </PrintShell>
  );
}

type DocProps = { d: BookingDocument; lang: AppLanguage; dt: TFunction };

function sellerName(d: BookingDocument) {
  return d.organization.legal_name || d.organization.name;
}

function DocTitle({ children, sub }: { children: ReactNode; sub?: ReactNode }) {
  return (
    <header className="mb-5 text-center">
      <h1 className="text-[14pt] font-bold">{children}</h1>
      {sub && <p className="mt-1">{sub}</p>}
    </header>
  );
}

function Requisites({ d, dt }: { d: BookingDocument; dt: TFunction }) {
  const o = d.organization;
  const rows: [string, string | null][] = [
    [dt("documents.req.bin"), o.bin], [dt("documents.req.address"), o.legal_address],
    [dt("documents.req.bank"), o.bank_name], [dt("documents.req.iik"), o.iik], [dt("documents.req.bik"), o.bik],
    [dt("documents.req.phone"), o.phone ? formatKzPhone(o.phone) : null], [dt("documents.req.email"), o.email],
  ];
  return (
    <div className="space-y-0.5">
      <p className="font-semibold">{sellerName(d)}</p>
      {rows.filter(([, v]) => v).map(([k, v]) => <p key={k}>{k}: {v}</p>)}
    </div>
  );
}

function Lines({ d, lang, dt }: DocProps) {
  return (
    <table className="doc-table w-full border-collapse text-[10pt]">
      <thead>
        <tr>
          <th className="w-8">№</th>
          <th className="text-left">{dt("documents.cols.name")}</th>
          <th>{dt("documents.cols.qty")}</th>
          <th>{dt("documents.cols.unit")}</th>
          <th className="text-right">{dt("documents.cols.price")}</th>
          <th className="text-right">{dt("documents.cols.amount")}</th>
        </tr>
      </thead>
      <tbody>
        {d.lines.map((l, i) => (
          <tr key={i}>
            <td className="text-center">{i + 1}</td>
            <td>
              {l.unit === "night" ? `${dt("documents.stay")}: ${l.name}, ${formatDate(d.booking.check_in, lang)} — ${formatDate(d.booking.check_out, lang)}` : l.name}
            </td>
            <td className="text-center">{formatNumber(l.quantity, lang, 2)}</td>
            <td className="text-center">{dt(`documents.units.${l.unit}`)}</td>
            <td className="whitespace-nowrap text-right">{money(l.price, lang)}</td>
            <td className="whitespace-nowrap text-right">{money(l.amount, lang)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function Totals({ d, lang, dt, showPaid }: DocProps & { showPaid: boolean }) {
  const vat = vatIncluded(d.total, d.organization.vat_rate);
  const rows: [string, number | null, boolean?][] = [
    [dt("documents.total"), d.total, true],
    [vat !== null ? dt("documents.vatIncluded", { rate: formatNumber(d.organization.vat_rate!, lang) }) : dt("documents.noVat"), vat],
  ];
  if (showPaid) rows.push([dt("documents.paid"), d.paid], [dt("documents.due"), d.due, true]);
  return (
    <div className="mt-2 flex justify-end">
      <table className="text-[10pt]">
        <tbody>
          {rows.map(([k, v, bold]) => (
            <tr key={k} className={bold ? "font-semibold" : undefined}>
              <td className="pr-4 text-right">{v === null ? k : `${k}:`}</td>
              <td className="whitespace-nowrap text-right">{v === null ? "" : money(v, lang)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Sign({ role, name, stamp, dt }: { role: string; name?: string | null; stamp?: boolean; dt: TFunction }) {
  return (
    <div className="min-w-0 flex-1">
      <p className="font-semibold">{role}</p>
      <p className="mt-6 border-b border-black" />
      <p className="mt-1 text-[9pt]">{dt("documents.signature")}{name ? ` / ${name}` : ""}</p>
      {stamp && <p className="mt-2 text-[9pt]">{dt("documents.stamp")}</p>}
    </div>
  );
}

function Invoice({ d, lang, dt }: DocProps) {
  return (
    <>
      <DocTitle sub={dt("documents.dated", { date: formatDate(d.document.issued_on, lang) })}>
        {dt("documents.title.invoice", { number: d.document.number })}
      </DocTitle>
      <div className="mb-4 grid grid-cols-[auto_1fr] gap-x-3 gap-y-2">
        <span className="text-[10pt]">{dt("documents.supplier")}:</span><Requisites d={d} dt={dt} />
        <span className="text-[10pt]">{dt("documents.buyer")}:</span>
        <span>{d.guest.full_name}{d.guest.phone ? `, ${formatKzPhone(d.guest.phone)}` : ""}</span>
        <span className="text-[10pt]">{dt("documents.basis")}:</span>
        <span>{dt("documents.basisBooking", { number: d.booking.number })}</span>
      </div>
      <Lines d={d} lang={lang} dt={dt} />
      <Totals d={d} lang={lang} dt={dt} showPaid />
      <p className="mt-3">{dt("documents.inWords")}: <b>{amountInWords(d.due, lang)}</b></p>
      <div className="mt-10 flex gap-10">
        <Sign role={dt("documents.director")} name={d.organization.director_name} stamp dt={dt} />
        <div className="flex-1" />
      </div>
    </>
  );
}

function Act({ d, lang, dt }: DocProps) {
  return (
    <>
      <DocTitle sub={dt("documents.dated", { date: formatDate(d.document.issued_on, lang) })}>
        {dt("documents.title.act", { number: d.document.number })}
      </DocTitle>
      <div className="mb-4 grid grid-cols-[auto_1fr] gap-x-3 gap-y-2">
        <span className="text-[10pt]">{dt("documents.executor")}:</span><Requisites d={d} dt={dt} />
        <span className="text-[10pt]">{dt("documents.customer")}:</span><span>{d.guest.full_name}</span>
        <span className="text-[10pt]">{dt("documents.period")}:</span>
        <span>{formatDate(d.booking.check_in, lang)} — {formatDate(d.booking.check_out, lang)} ({dt("documents.basisBooking", { number: d.booking.number })})</span>
      </div>
      <Lines d={d} lang={lang} dt={dt} />
      <Totals d={d} lang={lang} dt={dt} showPaid={false} />
      <p className="mt-3">{dt("documents.inWords")}: <b>{amountInWords(d.total, lang)}</b></p>
      <p className="mt-3">{dt("documents.actNoClaims")}</p>
      <div className="mt-10 flex gap-10">
        <Sign role={dt("documents.executor")} name={d.organization.director_name} stamp dt={dt} />
        <Sign role={dt("documents.customer")} name={d.guest.full_name} dt={dt} />
      </div>
    </>
  );
}

function Contract({ d, lang, dt }: DocProps) {
  const o = d.organization;
  const b = d.booking;
  const vat = vatIncluded(d.total, o.vat_rate);
  const terms = o.contract_terms?.trim() || dt("documents.contract.defaultTerms");
  return (
    <>
      <DocTitle sub={dt("documents.contract.subtitle")}>{dt("documents.title.contract", { number: d.document.number })}</DocTitle>
      <div className="mb-4 flex justify-between text-[10pt]">
        <span>{o.city ?? ""}</span><span>{formatDate(d.document.issued_on, lang)}</span>
      </div>
      <p className="text-justify">
        {dt("documents.contract.parties", {
          seller: sellerName(d), bin: o.bin ?? "____________", director: o.director_name ?? "____________", guest: d.guest.full_name,
        })}
      </p>
      <h2 className="mt-4 font-semibold">1. {dt("documents.contract.subject")}</h2>
      <p className="text-justify">
        {dt("documents.contract.subjectText", {
          roomType: b.room_type, room: b.room ? `, № ${b.room}` : "",
          from: formatDate(b.check_in, lang), to: formatDate(b.check_out, lang),
          checkIn: o.check_in_time ?? "14:00", checkOut: o.check_out_time ?? "12:00",
          nights: b.nights, adults: b.adults, children: b.children,
        })}
      </p>
      <div className="mt-2"><Lines d={d} lang={lang} dt={dt} /></div>
      <h2 className="mt-4 font-semibold">2. {dt("documents.contract.price")}</h2>
      <p className="text-justify">
        {dt("documents.contract.priceText", { total: money(d.total, lang), words: amountInWords(d.total, lang) })}{" "}
        {vat !== null ? dt("documents.vatIncludedSum", { rate: formatNumber(o.vat_rate!, lang), sum: money(vat, lang) }) : dt("documents.noVat")}.{" "}
        {dt("documents.contract.paidText", { paid: money(d.paid, lang), due: money(d.due, lang) })}
      </p>
      <h2 className="mt-4 font-semibold">3. {dt("documents.contract.terms")}</h2>
      <p className="whitespace-pre-line text-justify">{terms}</p>
      <h2 className="mt-4 font-semibold">4. {dt("documents.contract.signatures")}</h2>
      <div className="mt-2 grid grid-cols-2 gap-8 text-[10pt]">
        <div>
          <p className="mb-1 font-semibold">{dt("documents.executor")}</p>
          <Requisites d={d} dt={dt} />
          <div className="mt-4"><Sign role="" name={o.director_name} stamp dt={dt} /></div>
        </div>
        <div className="space-y-0.5">
          <p className="mb-1 font-semibold">{dt("documents.customer")}</p>
          <p>{d.guest.full_name}</p>
          {d.guest.birth_date && <p>{dt("documents.birthDate")}: {formatDate(d.guest.birth_date, lang)}</p>}
          <p>{dt("documents.iin")}: ____________________</p>
          <p>{dt("documents.idDoc")}: ____________________</p>
          {d.guest.phone && <p>{dt("documents.req.phone")}: {formatKzPhone(d.guest.phone)}</p>}
          <div className="mt-4"><Sign role="" dt={dt} /></div>
        </div>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Выписка из медкарты (открытие пишется в журнал, как и просмотр карты)
// ---------------------------------------------------------------------------

export function MedicalExtractPage() {
  const { guestId = "" } = useParams();
  const { t } = useTranslation();
  const { org } = useOrg();
  const { lang, setLang, dt } = useDocLang();

  const card = useQuery({
    queryKey: ["medical-card", guestId],
    staleTime: Infinity,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_medical_card", { p_guest_id: guestId });
      if (error) throw error;
      return data as MedicalCard;
    },
  });

  if (card.isLoading) return <Loading />;
  if (card.error) return <div className="mx-auto max-w-xl p-6"><ErrorState error={card.error} onRetry={() => card.refetch()} /></div>;
  const c = card.data!;
  const today = todayInTimeZone(org.timezone);
  const age = ageOn(c.guest.birth_date, today);
  const stayVisits = c.stay ? c.visits.filter((v) => v.booking_id === c.stay!.id) : c.visits;
  const visits = [...(stayVisits.length ? stayVisits : c.visits)].reverse();
  const rx = c.stay ? c.prescriptions.filter((p) => p.booking_id === c.stay!.id || !p.booking_id) : c.prescriptions;
  const last = visits[visits.length - 1];

  return (
    <PrintShell back={`/app/${org.slug}/medical/${guestId}`} lang={lang} onLang={setLang}
      warning={!c.record ? t("medical.noRecord") : undefined}>
      <p className="text-center text-[10pt]">{org.legal_name || org.name}</p>
      <DocTitle sub={formatDate(today, lang)}>{dt("documents.title.medical")}</DocTitle>
      <dl className="mb-4 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        <dt>{dt("documents.patient")}:</dt>
        <dd className="font-semibold">{c.guest.full_name}{age !== null ? `, ${dt("medical.age", { count: age })}` : ""}</dd>
        {c.guest.birth_date && (<><dt>{dt("documents.birthDate")}:</dt><dd>{formatDate(c.guest.birth_date, lang)}</dd></>)}
        {c.stay && (<><dt>{dt("documents.period")}:</dt><dd>{formatDate(c.stay.check_in, lang)} — {formatDate(c.stay.check_out, lang)}</dd></>)}
      </dl>

      {c.record && (
        <section className="mb-4">
          <h2 className="mb-1 font-semibold">{dt("medical.record")}</h2>
          {RECORD_FIELDS.filter((f) => f !== "notes" && c.record![f]).map((f) => (
            <p key={f}><span className="font-medium">{dt(`medical.fields.${f}`)}:</span> {c.record![f]}</p>
          ))}
        </section>
      )}

      {visits.length > 0 && (
        <section className="mb-4">
          <h2 className="mb-1 font-semibold">{dt("medical.visits")}</h2>
          {visits.map((v) => (
            <div key={v.id} className="mb-2 break-inside-avoid">
              <p className="font-medium">{formatDate(v.visit_at.slice(0, 10), lang)} · {dt(`medical.kind.${v.kind}`)}{v.doctor_name ? ` · ${v.doctor_name}` : ""}</p>
              <p>
                {[v.blood_pressure && `${dt("medical.fields.blood_pressure")} ${v.blood_pressure}`, v.pulse !== null && `${dt("medical.fields.pulse")} ${v.pulse}`,
                  v.temperature !== null && `${dt("medical.fields.temperature")} ${v.temperature} °C`, v.weight !== null && `${dt("medical.fields.weight")} ${v.weight} ${dt("medical.kg")}`]
                  .filter(Boolean).join(" · ")}
              </p>
              {(["complaints", "diagnosis"] as const).filter((f) => v[f]).map((f) => (
                <p key={f}><span className="font-medium">{dt(`medical.fields.${f}`)}:</span> {v[f]}</p>
              ))}
            </div>
          ))}
        </section>
      )}

      {rx.length > 0 && (
        <section className="mb-4">
          <h2 className="mb-1 font-semibold">{dt("documents.treatment")}</h2>
          <table className="doc-table w-full border-collapse text-[10pt]">
            <thead><tr><th className="text-left">{dt("medical.procedure")}</th><th>{dt("documents.sessionsDone")}</th><th className="text-left">{dt("medical.frequency")}</th></tr></thead>
            <tbody>
              {rx.filter((p) => p.status !== "cancelled").map((p) => (
                <tr key={p.id}><td>{p.procedure}</td><td className="text-center">{p.done} / {p.sessions}</td><td>{p.frequency ?? ""}</td></tr>
              ))}
            </tbody>
          </table>
        </section>
      )}

      {last?.recommendations && (
        <section className="mb-4">
          <h2 className="mb-1 font-semibold">{dt("medical.fields.recommendations")}</h2>
          <p className="whitespace-pre-line">{last.recommendations}</p>
        </section>
      )}

      <div className="mt-10 flex gap-10">
        <Sign role={dt("documents.doctor")} name={last?.doctor_name} dt={dt} />
        <div className="flex-1" />
      </div>
    </PrintShell>
  );
}
