import { describe, expect, it } from "vitest";
import type { TFunction } from "i18next";
import { describeLeadError, isContactOverdue, leadStatusesFor, sortLeads, type Lead } from "./leads";

const now = Date.parse("2026-10-25T12:00:00Z");
const lead = (over: Partial<Lead>): Pick<Lead, "status" | "next_contact_at" | "created_at"> & { id: string } => ({
  id: "x", status: "new", next_contact_at: null, created_at: "2026-10-20T00:00:00Z", ...over,
});
const t = ((key: string) => key) as unknown as TFunction;

describe("leads", () => {
  it("maps tabs to statuses", () => {
    expect(leadStatusesFor("open")).toEqual(["new", "in_progress"]);
    expect(leadStatusesFor("lost")).toEqual(["lost"]);
    expect(leadStatusesFor("all")).toBeNull();
  });
  it("marks an overdue contact only for open leads", () => {
    expect(isContactOverdue(lead({ next_contact_at: "2026-10-25T11:00:00Z" }), now)).toBe(true);
    expect(isContactOverdue(lead({ next_contact_at: "2026-10-25T13:00:00Z" }), now)).toBe(false);
    expect(isContactOverdue(lead({ next_contact_at: "2026-10-25T11:00:00Z", status: "won" }), now)).toBe(false);
  });
  it("sorts overdue first, then the nearest contact, then newest", () => {
    const list = [
      lead({ id: "closed", status: "lost", created_at: "2026-10-24T00:00:00Z" }),
      lead({ id: "newest", created_at: "2026-10-24T00:00:00Z" }),
      lead({ id: "later", next_contact_at: "2026-10-27T09:00:00Z" }),
      lead({ id: "soon", next_contact_at: "2026-10-26T09:00:00Z" }),
      lead({ id: "late", next_contact_at: "2026-10-24T09:00:00Z" }),
      lead({ id: "older", created_at: "2026-10-21T00:00:00Z" }),
    ];
    expect(sortLeads(list, now).map((l) => l.id)).toEqual(["late", "soon", "later", "newest", "older", "closed"]);
  });
  it("explains server errors", () => {
    expect(describeLeadError({ message: "lost reason is required" }, t)).toBe("leads.errors.reason");
    expect(describeLeadError({ message: "lead already has a booking" }, t)).toBe("leads.errors.hasBooking");
    expect(describeLeadError({ message: "permission denied", code: "42501" }, t)).toBe("common.forbiddenText");
  });
});
