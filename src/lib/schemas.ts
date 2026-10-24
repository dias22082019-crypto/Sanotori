import { z } from "zod";
import { isKaspiUrl, normalizeKzPhone, SLUG_PATTERN } from "./format";

/** Сообщения — ключи i18n; перевод выполняется при выводе ошибки */
export const emailSchema = z.string().trim().min(1, "validation.required").email("validation.email").max(254, "validation.tooLong");

export const passwordSchema = z
  .string()
  .min(8, "validation.passwordMin")
  .max(72, "validation.tooLong")
  .refine((v) => /[A-Za-zА-Яа-яЁёӘәҒғҚқҢңӨөҰұҮүҺһІі]/.test(v) && /\d/.test(v), "validation.passwordMix");

export const loginSchema = z.object({ email: emailSchema, password: z.string().min(1, "validation.required") });

export const registerSchema = z.object({
  fullName: z.string().trim().min(1, "validation.required").max(200, "validation.tooLong"),
  email: emailSchema,
  password: passwordSchema,
  consent: z.literal(true, { errorMap: () => ({ message: "validation.consent" }) }),
});

export const optionalKzPhone = z
  .string()
  .trim()
  .transform((v, ctx) => {
    if (v === "") return null;
    const phone = normalizeKzPhone(v);
    if (!phone) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "validation.phone" });
      return z.NEVER;
    }
    return phone;
  });

export const organizationCreateSchema = z.object({
  name: z.string().trim().min(2, "validation.required").max(200, "validation.tooLong"),
  slug: z.string().trim().toLowerCase().regex(SLUG_PATTERN, "validation.slug"),
  city: z.string().trim().max(100, "validation.tooLong"),
  language: z.enum(["ru", "kk"]),
});

const optionalText = (max: number) =>
  z.string().trim().max(max, "validation.tooLong").transform((v) => (v === "" ? null : v));

export const organizationSettingsSchema = z.object({
  name: z.string().trim().min(2, "validation.required").max(200, "validation.tooLong"),
  description: optionalText(5000),
  address: optionalText(300),
  city: optionalText(100),
  phone: optionalKzPhone,
  email: z.string().trim().max(254).refine((v) => v === "" || z.string().email().safeParse(v).success, "validation.email")
    .transform((v) => (v === "" ? null : v)),
  whatsapp_phone: optionalKzPhone,
  legal_name: optionalText(300),
  bin: z.string().trim().refine((v) => v === "" || /^\d{12}$/.test(v), "settings.binInvalid").transform((v) => (v === "" ? null : v)),
  timezone: z.string().min(1, "validation.required"),
  default_language: z.enum(["ru", "kk"]),
  is_published: z.boolean(),
  kaspi_pay_url: z.string().trim().max(500, "validation.tooLong")
    .refine((v) => v === "" || isKaspiUrl(v), "kaspi.urlInvalid")
    .transform((v) => (v === "" ? null : v)),
});

export type OrganizationSettingsInput = z.input<typeof organizationSettingsSchema>;

/** Телефон гостя: казахстанский номер в любом написании или иностранный в формате +XXXXXXXX */
export const optionalGuestPhone = z
  .string()
  .trim()
  .transform((v, ctx) => {
    if (v === "") return null;
    const kz = normalizeKzPhone(v);
    if (kz) return kz;
    const intl = `+${v.replace(/\D/g, "")}`;
    if (v.startsWith("+") && /^\+[1-9]\d{6,14}$/.test(intl)) return intl;
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "validation.phone" });
    return z.NEVER;
  });

export const guestSchema = z.object({
  full_name: z.string().trim().min(2, "validation.required").max(200, "validation.tooLong"),
  phone: optionalGuestPhone,
  email: z.string().trim().max(254).refine((v) => v === "" || z.string().email().safeParse(v).success, "validation.email")
    .transform((v) => (v === "" ? null : v)),
  birth_date: z.string().transform((v) => (v === "" ? null : v)),
  city: optionalText(120),
  notes: optionalText(2000),
});

/** Заявка на бронирование с публичной страницы */
export const bookingRequestSchema = z.object({
  room_type_id: z.string().uuid("validation.required"),
  check_in: z.string().min(1, "validation.required"),
  check_out: z.string().min(1, "validation.required"),
  adults: z.coerce.number().int().min(1, "validation.number").max(30, "validation.number"),
  children: z.coerce.number().int().min(0, "validation.number").max(30, "validation.number"),
  full_name: z.string().trim().min(2, "validation.required").max(200, "validation.tooLong"),
  phone: z.string().trim().transform((v, ctx) => {
    const phone = normalizeKzPhone(v);
    if (!phone) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "validation.phone" });
      return z.NEVER;
    }
    return phone;
  }),
  comment: z.string().trim().max(1000, "validation.tooLong"),
  consent: z.literal(true, { errorMap: () => ({ message: "validation.consent" }) }),
}).refine((v) => v.check_out > v.check_in, { path: ["check_out"], message: "bookings.errors.dates" });
