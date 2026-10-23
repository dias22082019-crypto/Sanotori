import { describe, expect, it } from "vitest";
import { addDays, dateRange, diffDays, staysOverlap } from "./bookings";
import { barPosition } from "@/pages/app/CalendarPage";
import { guestSearchFilter } from "@/pages/app/GuestsPage";
import { bookingRequestSchema, guestSchema } from "./schemas";

describe("calendar dates", () => {
  it("adds days across month and year boundaries", () => {
    expect(addDays("2026-10-31", 1)).toBe("2026-11-01");
    expect(addDays("2026-12-31", 1)).toBe("2027-01-01");
    expect(addDays("2028-03-01", -1)).toBe("2028-02-29");
  });
  it("counts nights", () => {
    expect(diffDays("2026-10-23", "2026-10-30")).toBe(7);
    expect(dateRange("2026-10-30", 3)).toEqual(["2026-10-30", "2026-10-31", "2026-11-01"]);
  });
  it("treats check-out day as free for the next arrival (same rule as the DB constraint)", () => {
    expect(staysOverlap("2026-10-01", "2026-10-05", "2026-10-05", "2026-10-07")).toBe(false);
    expect(staysOverlap("2026-10-01", "2026-10-05", "2026-10-04", "2026-10-07")).toBe(true);
  });
});

describe("chessboard bar", () => {
  it("runs from mid check-in day to mid check-out day", () => {
    expect(barPosition("2026-10-01", 14, "2026-10-02", "2026-10-04")).toEqual({ left: 1.5, width: 2 });
  });
  it("is clipped to the visible period", () => {
    expect(barPosition("2026-10-01", 14, "2026-09-20", "2026-10-03")).toEqual({ left: 0, width: 2.5 });
    expect(barPosition("2026-10-01", 14, "2026-10-14", "2026-10-30")).toEqual({ left: 13.5, width: 0.5 });
    expect(barPosition("2026-10-01", 14, "2026-11-01", "2026-11-03")).toBeNull();
  });
});

describe("guest search", () => {
  it("ignores short terms and strips filter syntax", () => {
    expect(guestSearchFilter("a")).toBeNull();
    expect(guestSearchFilter("Иванов),id.eq.1")).not.toContain("(");
    expect(guestSearchFilter("Иванов),id.eq.1")).not.toContain("),");
  });
  it("searches phones by digits, 8 prefix as 7", () => {
    expect(guestSearchFilter("8 701 123")).toContain("phone.like.%7701123%");
    expect(guestSearchFilter("701 12")).toContain("phone.like.%70112%");
    expect(guestSearchFilter("87011234567")).toContain("phone.like.%77011234567%");
  });
});

describe("guest form", () => {
  const base = { full_name: "Ержан Сапаров", email: "", birth_date: "", city: "", notes: "" };
  it("normalizes Kazakhstan and accepts foreign phones", () => {
    expect(guestSchema.parse({ ...base, phone: "8 (701) 123-45-67" }).phone).toBe("+77011234567");
    expect(guestSchema.parse({ ...base, phone: "+998 90 123 45 67" }).phone).toBe("+998901234567");
    expect(guestSchema.parse({ ...base, phone: "" }).phone).toBeNull();
    expect(guestSchema.safeParse({ ...base, phone: "12345" }).success).toBe(false);
  });
});

describe("public booking request", () => {
  const ok = {
    room_type_id: "8f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b", check_in: "2026-11-01", check_out: "2026-11-08",
    adults: "2", children: "0", full_name: "Айжан", phone: "87771234567", comment: "", consent: true,
  };
  it("accepts a valid request and normalizes the phone", () => {
    const v = bookingRequestSchema.parse(ok);
    expect(v.phone).toBe("+77771234567");
    expect(v.adults).toBe(2);
  });
  it("requires consent and check-out after check-in", () => {
    expect(bookingRequestSchema.safeParse({ ...ok, consent: false }).success).toBe(false);
    expect(bookingRequestSchema.safeParse({ ...ok, check_out: "2026-11-01" }).success).toBe(false);
  });
});
