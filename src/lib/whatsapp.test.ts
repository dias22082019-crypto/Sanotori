import { describe, expect, it } from "vitest";
import type { TFunction } from "i18next";
import { isKaspiUrl } from "./format";
import { organizationSettingsSchema } from "./schemas";
import { TEMPLATE_LANG_PATTERN, TEMPLATE_NAME_PATTERN, describeWhatsappError, kaspiPaymentText, webhookUrl } from "./whatsapp";

const t = ((key: string, opts?: Record<string, unknown>) => (opts ? `${key} ${JSON.stringify(opts)}` : key)) as unknown as TFunction;

describe("kaspi", () => {
  it("accepts only https links on kaspi.kz", () => {
    expect(isKaspiUrl("https://pay.kaspi.kz/pay/abc123")).toBe(true);
    expect(isKaspiUrl("https://kaspi.kz/pay/Sanatorium")).toBe(true);
    expect(isKaspiUrl("http://pay.kaspi.kz/pay/abc")).toBe(false);
    expect(isKaspiUrl("https://kaspi.kz.evil.com/pay")).toBe(false);
    expect(isKaspiUrl("https://evilkaspi.kz/pay")).toBe(false);
    expect(isKaspiUrl("https://pay.kaspi.kz/pay/a b")).toBe(false);
  });
  it("validates the settings field and stores an empty value as null", () => {
    const base = { name: "Алтын", description: "", address: "", city: "", phone: "", email: "", whatsapp_phone: "",
      legal_name: "", bin: "", timezone: "Asia/Almaty", default_language: "ru" as const, is_published: false };
    expect(organizationSettingsSchema.parse({ ...base, kaspi_pay_url: "" }).kaspi_pay_url).toBeNull();
    expect(organizationSettingsSchema.parse({ ...base, kaspi_pay_url: " https://pay.kaspi.kz/pay/x " }).kaspi_pay_url).toBe("https://pay.kaspi.kz/pay/x");
    expect(organizationSettingsSchema.safeParse({ ...base, kaspi_pay_url: "https://example.com" }).success).toBe(false);
  });
  it("builds the payment message with the amount in tenge", () => {
    const text = kaspiPaymentText(t, { name: "Алтын", number: 42, amount: 150000, url: "https://pay.kaspi.kz/pay/x", lang: "ru" });
    expect(text).toContain("\"number\":42");
    expect(text).toContain("150");
    expect(text).toContain("https://pay.kaspi.kz/pay/x");
  });
});

describe("whatsapp", () => {
  it("builds the webhook address from the project URL", () => {
    expect(webhookUrl("https://abc.supabase.co/")).toBe("https://abc.supabase.co/functions/v1/whatsapp-webhook");
  });
  it("checks template names and languages like the database", () => {
    expect(TEMPLATE_NAME_PATTERN.test("booking_reminder")).toBe(true);
    expect(TEMPLATE_NAME_PATTERN.test("Booking Reminder")).toBe(false);
    expect(TEMPLATE_LANG_PATTERN.test("ru")).toBe(true);
    expect(TEMPLATE_LANG_PATTERN.test("en_US")).toBe(true);
    expect(TEMPLATE_LANG_PATTERN.test("russian")).toBe(false);
  });
  it("maps server and Meta errors to messages", () => {
    expect(describeWhatsappError({ message: "whatsapp 24h window is closed" }, t)).toBe("messages.errors.window");
    expect(describeWhatsappError({ message: "(#131047) Re-engagement message" }, t)).toBe("messages.errors.window");
    expect(describeWhatsappError({ message: "whatsapp is not connected" }, t)).toBe("messages.errors.notConnected");
    expect(describeWhatsappError({ message: "integrations are not available", code: "42501" }, t)).toBe("whatsapp.planNote");
    expect(describeWhatsappError({ message: "whatsapp number is used by another sanatorium", code: "23505" }, t)).toBe("whatsapp.errors.duplicate");
    expect(describeWhatsappError({ message: "(#190) Error validating access token" }, t)).toBe("whatsapp.errors.token");
    expect(describeWhatsappError({ code: "PGRST202", message: "Could not find the function public.whatsapp_settings" }, t)).toBe("whatsapp.errors.migration");
    expect(describeWhatsappError({ message: "permission denied", code: "42501" }, t)).toBeNull();
  });
});
