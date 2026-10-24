import { describe, expect, it } from "vitest";
import { ageOn, isBloodPressure, overviewNeeds, parseMeasure } from "./medical";

describe("ageOn", () => {
  it("counts full years and handles missing birth date", () => {
    expect(ageOn("1980-05-10", "2026-05-09")).toBe(45);
    expect(ageOn("1980-05-10", "2026-05-10")).toBe(46);
    expect(ageOn(null, "2026-05-10")).toBeNull();
  });
});

describe("vitals input", () => {
  it("accepts blood pressure as 120/80 or empty", () => {
    expect(isBloodPressure("120/80")).toBe(true);
    expect(isBloodPressure(" ")).toBe(true);
    expect(isBloodPressure("120-80")).toBe(false);
    expect(isBloodPressure("1200/80")).toBe(false);
  });
  it("parses measures with comma and keeps bad input visible as NaN", () => {
    expect(parseMeasure("36,6")).toBe(36.6);
    expect(parseMeasure("")).toBeNull();
    expect(parseMeasure("абв")).toBeNaN();
  });
});

describe("overviewNeeds", () => {
  it("asks for the card first, then the initial visit", () => {
    expect(overviewNeeds({ has_card: false, has_initial: false })).toBe("card");
    expect(overviewNeeds({ has_card: true, has_initial: false })).toBe("initial");
    expect(overviewNeeds({ has_card: true, has_initial: true })).toBeNull();
  });
});
