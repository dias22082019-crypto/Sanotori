import { describe, expect, it } from "vitest";
import { formatKzt } from "./format";
import { PROMO_PATTERN, normalizePromoCode, promoValueText, reviewUrl, starsText } from "./marketing";

describe("marketing", () => {
  it("normalizes promo codes like the server", () => {
    expect(normalizePromoCode(" leto 10 ")).toBe("LETO10");
    expect(PROMO_PATTERN.test("LETO10")).toBe(true);
    expect(PROMO_PATTERN.test("AB")).toBe(false);
    expect(PROMO_PATTERN.test("ЛЕТО")).toBe(false);
    expect(PROMO_PATTERN.test("-ABC")).toBe(false);
  });
  it("formats promo values", () => {
    expect(promoValueText({ kind: "percent", value: "10.00" })).toBe("10%");
    expect(promoValueText({ kind: "fixed", value: 5000 })).toBe(formatKzt(5000));
  });
  it("builds review links under the app base path", () => {
    expect(reviewUrl("abc", "https://x.github.io", "/Sanotori/")).toBe("https://x.github.io/Sanotori/review/abc");
    expect(reviewUrl("abc", "https://crm.kz", "/")).toBe("https://crm.kz/review/abc");
  });
  it("renders stars", () => {
    expect(starsText(4)).toBe("★★★★☆");
    expect(starsText(9)).toBe("★★★★★");
  });
});
