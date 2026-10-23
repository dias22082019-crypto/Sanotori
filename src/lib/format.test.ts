import { describe, expect, it } from "vitest";
import { formatKzt, normalizeKzPhone, formatKzPhone, slugify, SLUG_PATTERN, todayInTimeZone, whatsappLink } from "./format";

describe("formatKzt", () => {
  it("formats tenge with the ₸ sign and grouping", () => {
    expect(formatKzt(125000).replace(/\s/g, " ")).toBe("125 000 ₸");
    expect(formatKzt("1500.50").replace(/\s/g, " ")).toBe("1 500,50 ₸");
  });
  it("shows a dash for invalid values", () => {
    expect(formatKzt("abc")).toBe("—");
  });
});

describe("normalizeKzPhone", () => {
  it.each([
    ["8 (701) 123-45-67", "+77011234567"],
    ["+7 701 123 45 67", "+77011234567"],
    ["7011234567", "+77011234567"],
    ["+7 727 250 00 00", "+77272500000"],
  ])("%s → %s", (input, expected) => {
    expect(normalizeKzPhone(input)).toBe(expected);
  });
  it.each(["123", "+1 555 123 4567", "8 (501) 123-45-67"])("rejects %s", (input) => {
    expect(normalizeKzPhone(input)).toBeNull();
  });
  it("pretty prints", () => {
    expect(formatKzPhone("+77011234567")).toBe("+7 701 123 45 67");
  });
});

describe("slugify", () => {
  it("transliterates Russian and Kazakh names into a valid slug", () => {
    expect(slugify("Санаторий Алатау")).toBe("sanatoriy-alatau");
    expect(slugify("Сарыағаш Шипа")).toBe("saryagash-shipa");
    expect(SLUG_PATTERN.test(slugify("Санаторий Алатау"))).toBe(true);
  });
});

describe("todayInTimeZone", () => {
  it("uses Asia/Almaty, not UTC", () => {
    // 20:30 UTC 31 декабря — в Алматы (UTC+5) уже 1 января
    expect(todayInTimeZone("Asia/Almaty", new Date("2026-12-31T20:30:00Z"))).toBe("2027-01-01");
  });
});

describe("whatsappLink", () => {
  it("builds a wa.me link with encoded text", () => {
    expect(whatsappLink("+77011234567", "Здравствуйте")).toBe("https://wa.me/77011234567?text=%D0%97%D0%B4%D1%80%D0%B0%D0%B2%D1%81%D1%82%D0%B2%D1%83%D0%B9%D1%82%D0%B5");
  });
});
