import { describe, expect, it } from "vitest";
import { kpis, occupancySeries, percent, presetRange, type AnalyticsReport } from "./analytics";

const report: AnalyticsReport = {
  from: "2026-03-01", to: "2026-03-31", days: 31, rooms: 3, room_nights: 6, accommodation: "170000.00",
  received: 55000, expenses: 12000, guests: 2, returning_guests: 1,
  daily: [{ day: "2026-03-01", occupied: 2 }, { day: "2026-03-02", occupied: 1 }],
  monthly: [{ month: "2026-03-01", days: 31, room_nights: 6, accommodation: 170000, received: 55000, expenses: 12000 }],
  bookings: { created: 4, cancelled: 1, no_show: 0, requests: 0, avg_nights: 2, avg_lead_days: 5 },
  sources: [], room_types: [], procedures: [],
};

describe("analytics", () => {
  it("presets follow the sanatorium calendar", () => {
    expect(presetRange("thisMonth", "2026-10-24")).toEqual({ from: "2026-10-01", to: "2026-10-24" });
    expect(presetRange("lastMonth", "2026-03-15")).toEqual({ from: "2026-02-01", to: "2026-02-28" });
    expect(presetRange("last3Months", "2026-01-10")).toEqual({ from: "2025-11-01", to: "2026-01-10" });
    expect(presetRange("thisYear", "2026-10-24")).toEqual({ from: "2026-01-01", to: "2026-10-24" });
  });
  it("computes occupancy, ADR and RevPAR", () => {
    expect(kpis(report)).toEqual({ occupancy: 6.5, adr: 28333, revpar: 1828, cancelRate: 25 });
    expect(kpis({ ...report, rooms: 0, room_nights: 0 })).toMatchObject({ occupancy: 0, adr: 0, revpar: 0 });
  });
  it("switches occupancy chart to months for long periods", () => {
    expect(occupancySeries(report)[0]).toEqual({ key: "2026-03-01", occupancy: 66.7, byMonth: false });
    expect(occupancySeries({ ...report, days: 120 })[0]).toEqual({ key: "2026-03-01", occupancy: 6.5, byMonth: true });
    expect(percent(1, 3)).toBe(33.3);
  });
});
