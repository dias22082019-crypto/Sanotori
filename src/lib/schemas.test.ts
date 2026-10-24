import { describe, expect, it } from "vitest";
import { organizationSettingsSchema, passwordSchema, registerSchema } from "./schemas";

describe("passwordSchema", () => {
  it("requires 8+ chars with letters and digits", () => {
    expect(passwordSchema.safeParse("short1").success).toBe(false);
    expect(passwordSchema.safeParse("longpassword").success).toBe(false);
    expect(passwordSchema.safeParse("пароль2026").success).toBe(true);
  });
});

describe("registerSchema", () => {
  it("rejects registration without personal data consent", () => {
    const r = registerSchema.safeParse({ fullName: "Айгерим", email: "a@example.kz", password: "secret123", consent: false });
    expect(r.success).toBe(false);
  });
});

describe("organizationSettingsSchema", () => {
  const base = {
    name: "Санаторий", description: "", address: "", city: "", phone: "", email: "", whatsapp_phone: "",
    legal_name: "", bin: "", timezone: "Asia/Almaty", default_language: "ru" as const, is_published: false, kaspi_pay_url: "",
  };
  it("normalizes Kazakhstan phones and empties to null", () => {
    const r = organizationSettingsSchema.parse({ ...base, phone: "8 (701) 123-45-67" });
    expect(r.phone).toBe("+77011234567");
    expect(r.email).toBeNull();
  });
  it("validates BIN length", () => {
    expect(organizationSettingsSchema.safeParse({ ...base, bin: "123" }).success).toBe(false);
    expect(organizationSettingsSchema.safeParse({ ...base, bin: "123456789012" }).success).toBe(true);
  });
});
