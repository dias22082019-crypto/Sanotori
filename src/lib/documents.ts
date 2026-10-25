import type { TFunction } from "i18next";
import { describeError } from "./errors";
import type { AppLanguage } from "./format";
import type { BookingStatus } from "./bookings";

export type DocumentKind = "contract" | "invoice" | "act";
export const DOCUMENT_KINDS: DocumentKind[] = ["contract", "invoice", "act"];

export interface DocumentLine {
  name: string;
  unit: "night" | "pcs" | "session";
  quantity: number;
  price: number;
  amount: number;
}

export interface BookingDocument {
  document: { kind: DocumentKind; number: number; issued_on: string };
  organization: {
    name: string; legal_name: string | null; bin: string | null; legal_address: string | null; city: string | null;
    phone: string | null; email: string | null; bank_name: string | null; iik: string | null; bik: string | null;
    director_name: string | null; vat_rate: number | null; contract_terms: string | null;
    check_in_time: string | null; check_out_time: string | null;
  };
  guest: { full_name: string; phone: string | null; email: string | null; birth_date: string | null; city: string | null };
  booking: {
    number: number; check_in: string; check_out: string; nights: number; adults: number; children: number;
    status: BookingStatus; discount: number; room_type: string; room: string | null;
  };
  lines: DocumentLine[];
  total: number;
  paid: number;
  due: number;
}

/** Какие документы можно напечатать по брони в этом статусе */
export function documentsFor(status: BookingStatus): DocumentKind[] {
  if (status === "checked_out") return ["contract", "invoice", "act"];
  if (status === "confirmed" || status === "checked_in") return ["contract", "invoice"];
  return [];
}

/** НДС в том числе: сумма × ставка / (100 + ставка), до тиынов */
export function vatIncluded(total: number, rate: number | null): number | null {
  if (!rate) return null;
  return Math.round((total * rate) / (100 + rate) * 100) / 100;
}

const RU = {
  units: ["", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"],
  unitsF: ["", "одна", "две", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"],
  teens: ["десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать", "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать"],
  tens: ["", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто"],
  hundreds: ["", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот"],
  scales: [
    null,
    { forms: ["тысяча", "тысячи", "тысяч"], female: true },
    { forms: ["миллион", "миллиона", "миллионов"], female: false },
    { forms: ["миллиард", "миллиарда", "миллиардов"], female: false },
  ],
};

function ruPlural(n: number, forms: string[]): string {
  const n10 = n % 10, n100 = n % 100;
  if (n10 === 1 && n100 !== 11) return forms[0];
  if (n10 >= 2 && n10 <= 4 && (n100 < 10 || n100 >= 20)) return forms[1];
  return forms[2];
}

function ruTriple(n: number, female: boolean): string[] {
  const out: string[] = [];
  const h = Math.floor(n / 100), rest = n % 100, t = Math.floor(rest / 10), u = rest % 10;
  if (h) out.push(RU.hundreds[h]);
  if (t === 1) out.push(RU.teens[u]);
  else {
    if (t) out.push(RU.tens[t]);
    if (u) out.push((female ? RU.unitsF : RU.units)[u]);
  }
  return out;
}

const KK = {
  units: ["", "бір", "екі", "үш", "төрт", "бес", "алты", "жеті", "сегіз", "тоғыз"],
  tens: ["", "он", "жиырма", "отыз", "қырық", "елу", "алпыс", "жетпіс", "сексен", "тоқсан"],
  scales: ["", "мың", "миллион", "миллиард"],
};

function kkTriple(n: number): string[] {
  const out: string[] = [];
  const h = Math.floor(n / 100), t = Math.floor((n % 100) / 10), u = n % 10;
  if (h) out.push(KK.units[h], "жүз");
  if (t) out.push(KK.tens[t]);
  if (u) out.push(KK.units[u]);
  return out;
}

/** Сумма прописью для счёта и акта: «Сто пятьдесят тысяч тенге 00 тиын» */
export function amountInWords(amount: number, lang: AppLanguage): string {
  const cents = Math.round(Math.abs(amount) * 100);
  let whole = Math.floor(cents / 100);
  const tiyn = String(cents % 100).padStart(2, "0");
  const words: string[] = [];
  if (whole === 0) words.push(lang === "kk" ? "нөл" : "ноль");
  for (let scale = 0; whole > 0 && scale < 4; scale++) {
    const triple = whole % 1000;
    whole = Math.floor(whole / 1000);
    if (!triple) continue;
    if (lang === "kk") {
      words.unshift(...kkTriple(triple), ...(KK.scales[scale] ? [KK.scales[scale]] : []));
    } else {
      const s = RU.scales[scale];
      words.unshift(...ruTriple(triple, s?.female ?? false), ...(s ? [ruPlural(triple, s.forms)] : []));
    }
  }
  const text = `${words.join(" ")} ${lang === "kk" ? "теңге" : "тенге"} ${tiyn} ${lang === "kk" ? "тиын" : "тиын"}`;
  return text.charAt(0).toUpperCase() + text.slice(1);
}

export function describeDocumentError(error: unknown, t: TFunction): string {
  const m = ((error ?? {}) as { message?: string }).message ?? "";
  if (/booking is not confirmed/.test(m)) return t("documents.errors.notConfirmed");
  if (/act requires check-out/.test(m)) return t("documents.errors.actCheckout");
  return describeError(error, t);
}
