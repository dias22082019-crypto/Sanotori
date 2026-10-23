import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, Users } from "lucide-react";
import type { z } from "zod";
import { supabase } from "@/lib/supabase";
import { bookingRequestSchema } from "@/lib/schemas";
import { formatKzt, todayInTimeZone, type AppLanguage } from "@/lib/format";
import { addDays, describeBookingError, diffDays } from "@/lib/bookings";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input, NativeSelect, Textarea } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";

interface PublicRoomType {
  id: string;
  name: string;
  description: string | null;
  base_occupancy: number;
  max_occupancy: number;
  price_from: string | number;
}

type RequestInput = z.input<typeof bookingRequestSchema>;
type RequestOutput = z.output<typeof bookingRequestSchema>;

/**
 * Номера и заявка на публичной странице. Заявка не гарантирует бронь: она попадает
 * администратору в статусе «заявка», он подтверждает её и выбирает номер.
 */
export function PublicBookingSection({ slug }: { slug: string }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const today = todayInTimeZone();
  const [sentNumber, setSentNumber] = useState<number | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);

  const types = useQuery({
    queryKey: ["public-room-types", slug],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_public_room_types", { p_slug: slug });
      if (error) throw error;
      return data as PublicRoomType[];
    },
  });

  const form = useForm<RequestInput, unknown, RequestOutput>({
    resolver: zodResolver(bookingRequestSchema),
    defaultValues: {
      room_type_id: "", check_in: addDays(today, 1), check_out: addDays(today, 8), adults: 2, children: 0,
      full_name: "", phone: "", comment: "", consent: false as unknown as true,
    },
  });
  const w = form.watch();
  const datesOk = Boolean(w.check_in && w.check_out) && diffDays(w.check_in, w.check_out) > 0 && diffDays(w.check_in, w.check_out) <= 60;

  const quote = useQuery({
    queryKey: ["public-quote", slug, w.room_type_id, w.check_in, w.check_out, w.adults, w.children],
    enabled: Boolean(w.room_type_id) && datesOk,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("public_quote", {
        p_slug: slug, p_room_type_id: w.room_type_id, p_check_in: w.check_in, p_check_out: w.check_out,
        p_adults: Number(w.adults) || 1, p_children: Number(w.children) || 0,
      });
      if (error) throw error;
      return data as { total: number; nights: number };
    },
  });

  const onSubmit = form.handleSubmit(async (v) => {
    setSubmitError(null);
    const { data, error } = await supabase.rpc("submit_booking_request", {
      p_slug: slug, p_room_type_id: v.room_type_id, p_check_in: v.check_in, p_check_out: v.check_out,
      p_adults: v.adults, p_children: v.children, p_full_name: v.full_name, p_phone: v.phone,
      p_comment: v.comment || null, p_consent: v.consent,
    });
    if (error) { setSubmitError(describeBookingError(error, t)); return; }
    setSentNumber(data as number);
  });

  if (types.isLoading || types.error || (types.data?.length ?? 0) === 0) {
    return types.isLoading ? null : (
      <p className="mt-8 rounded-lg border border-dashed bg-card p-4 text-sm text-muted-foreground">{t("public.roomsSoon")}</p>
    );
  }

  const e = form.formState.errors;
  const err = (m?: string) => (m ? t(m) : undefined);

  return (
    <>
      <h2 className="mt-8 text-lg font-semibold">{t("public.booking.roomsTitle")}</h2>
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        {types.data!.map((rt) => (
          <button key={rt.id} type="button"
            onClick={() => { form.setValue("room_type_id", rt.id, { shouldValidate: true }); document.getElementById("booking-form")?.scrollIntoView({ behavior: "smooth" }); }}
            className={`flex flex-col items-start rounded-lg border bg-card p-4 text-left transition-colors hover:border-primary ${w.room_type_id === rt.id ? "border-primary ring-1 ring-primary" : ""}`}>
            <p className="font-medium">{rt.name}</p>
            <p className="mt-1 flex items-center gap-1 text-xs text-muted-foreground"><Users className="h-3.5 w-3.5" />{t("public.booking.upTo", { count: rt.max_occupancy })}</p>
            {rt.description && <p className="mt-2 line-clamp-3 text-sm text-foreground/80">{rt.description}</p>}
            <p className="mt-3 text-sm">{t("public.booking.priceFrom", { price: formatKzt(rt.price_from, lang) })}</p>
          </button>
        ))}
      </div>

      <section id="booking-form" className="mt-8 rounded-lg border bg-card p-5">
        <h2 className="text-lg font-semibold">{t("public.booking.formTitle")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("public.booking.formText")}</p>

        {sentNumber !== null ? (
          <div className="mt-4 flex gap-3 rounded-md bg-accent p-4 text-sm">
            <CheckCircle2 className="h-5 w-5 shrink-0 text-success" />
            <div>
              <p className="font-medium">{t("public.booking.sentTitle", { number: sentNumber })}</p>
              <p className="mt-1 text-muted-foreground">{t("public.booking.sentText")}</p>
            </div>
          </div>
        ) : (
          <form onSubmit={onSubmit} className="mt-4 grid gap-3" noValidate>
            <FormField id="req-type" label={t("bookings.fields.roomType")} error={err(e.room_type_id?.message)}>
              <NativeSelect id="req-type" {...form.register("room_type_id")}>
                <option value="">{t("public.booking.chooseRoom")}</option>
                {types.data!.map((rt) => <option key={rt.id} value={rt.id}>{rt.name}</option>)}
              </NativeSelect>
            </FormField>
            <div className="grid grid-cols-2 gap-3">
              <FormField id="req-in" label={t("bookings.fields.checkIn")} error={err(e.check_in?.message)}>
                <Input id="req-in" type="date" min={today} {...form.register("check_in")} />
              </FormField>
              <FormField id="req-out" label={t("bookings.fields.checkOut")} error={err(e.check_out?.message)}>
                <Input id="req-out" type="date" min={w.check_in ? addDays(w.check_in, 1) : today} {...form.register("check_out")} />
              </FormField>
              <FormField id="req-adults" label={t("bookings.fields.adults")} error={err(e.adults?.message)}>
                <Input id="req-adults" type="number" min={1} max={30} {...form.register("adults")} />
              </FormField>
              <FormField id="req-children" label={t("bookings.fields.children")} error={err(e.children?.message)}>
                <Input id="req-children" type="number" min={0} max={30} {...form.register("children")} />
              </FormField>
              <FormField id="req-name" label={t("public.booking.name")} error={err(e.full_name?.message)}>
                <Input id="req-name" autoComplete="name" {...form.register("full_name")} />
              </FormField>
              <FormField id="req-phone" label={t("public.phone")} error={err(e.phone?.message)}>
                <Input id="req-phone" type="tel" autoComplete="tel" placeholder="+7 7XX XXX XX XX" {...form.register("phone")} />
              </FormField>
            </div>
            <FormField id="req-comment" label={`${t("bookings.fields.comment")} (${t("common.optional")})`} error={err(e.comment?.message)}>
              <Textarea id="req-comment" rows={2} placeholder={t("public.booking.commentPlaceholder")} {...form.register("comment")} />
            </FormField>

            {w.room_type_id && datesOk && (
              <div className="flex items-center justify-between rounded-md bg-accent px-3 py-2 text-sm">
                <span>{t("public.booking.estimate", { count: diffDays(w.check_in, w.check_out) })}</span>
                <span className="font-semibold">{quote.data ? formatKzt(quote.data.total, lang) : quote.error ? t("bookings.errors.capacity") : "…"}</span>
              </div>
            )}

            <label className="flex items-start gap-2 text-sm">
              <Checkbox className="mt-0.5" checked={w.consent === true} onCheckedChange={(c) => form.setValue("consent", (c === true) as true, { shouldValidate: true })} />
              <span>{t("public.booking.consent")}</span>
            </label>
            {e.consent && <p role="alert" className="-mt-2 text-xs text-destructive">{t(e.consent.message ?? "validation.consent")}</p>}

            {submitError && <p role="alert" className="rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm text-destructive">{submitError}</p>}
            <Button type="submit" size="lg" disabled={form.formState.isSubmitting}>
              {form.formState.isSubmitting ? t("common.saving") : t("public.booking.submit")}
            </Button>
            <p className="text-xs text-muted-foreground">{t("public.booking.disclaimer")}</p>
          </form>
        )}
      </section>
    </>
  );
}
