import { describe, expect, it } from "vitest";
import type { TFunction } from "i18next";
import { auditActionLabel, auditDetailsText, auditGroupFilter } from "./audit";

const dict: Record<string, string> = {
  "audit.actions.room_type_update": "Изменена категория номеров",
  "audit.fields.base_price": "цена",
  "audit.fields.phone": "телефон",
  "audit.changedFields": "изменены поля",
  "bookings.status.confirmed": "Подтверждена",
  "audit.yes": "да",
};
const t = ((k: string) => dict[k] ?? k) as unknown as TFunction;

describe("audit", () => {
  it("builds PostgREST group filter", () => {
    expect(auditGroupFilter("tasks")).toBe("action.like.task.*");
    expect(auditGroupFilter("catalog")).toContain("action.like.room.create");
  });
  it("falls back to the action code", () => {
    expect(auditActionLabel("room_type.update", t)).toBe("Изменена категория номеров");
    expect(auditActionLabel("new.thing", t)).toBe("new.thing");
  });
  it("describes changes without ids", () => {
    const text = auditDetailsText({ values: { base_price: { from: 30000, to: 34000 } }, changed: ["base_price", "phone"], room_id: "x" }, "ru", t);
    expect(text).toContain("цена:");
    expect(text).toContain("→");
    expect(text).toContain("изменены поля: телефон");
    expect(text).not.toContain("room_id");
  });
  it("translates statuses and booleans", () => {
    expect(auditDetailsText({ status: "confirmed", is_active: true }, "ru", t)).toBe("status: Подтверждена · is_active: да");
  });
});
