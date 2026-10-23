import { z } from "zod";
import { normalizeKzPhone, SLUG_PATTERN } from "./format";

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
});

export type OrganizationSettingsInput = z.input<typeof organizationSettingsSchema>;
