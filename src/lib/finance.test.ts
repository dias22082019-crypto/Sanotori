import { describe, expect, it } from "vitest";
import { monthBounds, parseAmount, toCsv } from "./finance";

describe("finance helpers", () => {
  it("parses amounts typed by cashiers", () => {
    expect(parseAmount("12 500")).toBe(12500);
    expect(parseAmount("12500,5")).toBe(12500.5);
    expect(parseAmount("0")).toBeNull();
    expect(parseAmount("10.005")).toBeNull();
    expect(parseAmount("-5")).toBeNull();
    expect(parseAmount("abc")).toBeNull();
  });
  it("returns month bounds including leap February", () => {
    expect(monthBounds("2026-10-24")).toEqual({ from: "2026-10-01", to: "2026-10-31" });
    expect(monthBounds("2028-02-10")).toEqual({ from: "2028-02-01", to: "2028-02-29" });
  });
  it("builds Excel-friendly CSV and neutralizes formulas", () => {
    const csv = toCsv([["Имя", "Сумма"], ['=HYPERLINK("x")', 100], ["a;b", null]]);
    expect(csv.startsWith("﻿")).toBe(true);
    expect(csv).toContain(`"'=HYPERLINK(""x"")"`);
    expect(csv).toContain('"a;b";');
  });
});

import { zonedDayStart } from "@/pages/app/FinancePage";

describe("period boundaries", () => {
  it("starts the day in the sanatorium time zone", () => {
    expect(zonedDayStart("2026-10-01", "Asia/Almaty")).toBe("2026-10-01T00:00:00+05:00");
    expect(zonedDayStart("2026-10-01", "UTC")).toBe("2026-10-01T00:00:00Z");
  });
});
