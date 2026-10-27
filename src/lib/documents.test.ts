import { describe, expect, it } from "vitest";
import { amountInWords, documentsFor, vatIncluded } from "./documents";

describe("amountInWords", () => {
  it("writes tenge in Russian with feminine thousands", () => {
    expect(amountInWords(150000, "ru")).toBe("Сто пятьдесят тысяч тенге 00 тиын");
    expect(amountInWords(1, "ru")).toBe("Один тенге 00 тиын");
    expect(amountInWords(2_021_511.5, "ru")).toBe("Два миллиона двадцать одна тысяча пятьсот одиннадцать тенге 50 тиын");
    expect(amountInWords(12_000, "ru")).toBe("Двенадцать тысяч тенге 00 тиын");
    expect(amountInWords(0, "ru")).toBe("Ноль тенге 00 тиын");
  });
  it("writes tenge in Kazakh", () => {
    expect(amountInWords(150000, "kk")).toBe("Бір жүз елу мың теңге 00 тиын");
    expect(amountInWords(2_045, "kk")).toBe("Екі мың қырық бес теңге 00 тиын");
    expect(amountInWords(1_000_000.07, "kk")).toBe("Бір миллион теңге 07 тиын");
  });
});

describe("documents", () => {
  it("offers the act only after check-out", () => {
    expect(documentsFor("confirmed")).toEqual(["contract", "invoice"]);
    expect(documentsFor("checked_out")).toEqual(["contract", "invoice", "act"]);
    expect(documentsFor("new_request")).toEqual([]);
    expect(documentsFor("cancelled")).toEqual([]);
  });
  it("computes VAT included in the total", () => {
    expect(vatIncluded(116000, 16)).toBe(16000);
    expect(vatIncluded(112000, 12)).toBe(12000);
    expect(vatIncluded(100000, null)).toBeNull();
  });
});
