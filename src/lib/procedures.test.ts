import { describe, expect, it } from "vitest";
import { compareTasks, isOverdue, type Task } from "./procedures";
import { dateInTimeZone, formatTime, zonedDateTime } from "./format";

const task = (over: Partial<Task>): Task => ({
  id: "x", title: "t", description: null, category: "other", priority: "normal", status: "open", source: "manual",
  assignee_id: null, room_id: null, due_at: null, created_by: null, completed_at: null, created_at: "2026-10-20T00:00:00Z", ...over,
});

describe("sanatorium local time", () => {
  it("turns a local date and time into an instant with the zone offset", () => {
    expect(zonedDateTime("2026-10-25", "10:30", "Asia/Almaty")).toBe("2026-10-25T10:30:00+05:00");
    expect(zonedDateTime("2026-10-25", "10:30:00", "UTC")).toBe("2026-10-25T10:30:00+00:00");
  });
  it("shows time and date in the sanatorium zone, not the browser zone", () => {
    expect(formatTime("2026-10-25T05:30:00Z", "ru", "Asia/Almaty")).toBe("10:30");
    expect(dateInTimeZone("2026-10-24T20:00:00Z", "Asia/Almaty")).toBe("2026-10-25");
  });
});

describe("tasks", () => {
  it("is overdue only while open", () => {
    const now = Date.parse("2026-10-25T12:00:00Z");
    expect(isOverdue(task({ due_at: "2026-10-25T11:00:00Z" }), now)).toBe(true);
    expect(isOverdue(task({ due_at: "2026-10-25T11:00:00Z", status: "done" }), now)).toBe(false);
    expect(isOverdue(task({ due_at: "2026-10-25T13:00:00Z" }), now)).toBe(false);
    expect(isOverdue(task({}), now)).toBe(false);
  });
  it("sorts open and urgent first, then by due time", () => {
    const list = [
      task({ id: "done", status: "done", priority: "high" }),
      task({ id: "low", priority: "low" }),
      task({ id: "late", due_at: "2026-10-25T09:00:00Z" }),
      task({ id: "high", priority: "high" }),
      task({ id: "later", due_at: "2026-10-26T09:00:00Z" }),
    ].sort(compareTasks);
    expect(list.map((x) => x.id)).toEqual(["high", "late", "later", "low", "done"]);
  });
});
