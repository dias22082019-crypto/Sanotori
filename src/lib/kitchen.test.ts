import { describe, expect, it } from "vitest";
import { portionGrid, sortDiets } from "./kitchen";

describe("kitchen", () => {
  it("sorts diets by order, then by code numerically", () => {
    const list = sortDiets([{ sort: 0, code: "10" }, { sort: 0, code: "9" }, { sort: -1, code: "15" }]);
    expect(list.map((d) => d.code)).toEqual(["15", "9", "10"]);
  });

  it("builds a portion grid in catalog order with meal totals", () => {
    const { rows, totals } = portionGrid({
      portions: [
        { meal: "breakfast", diet_type_id: "d15", portions: 2 },
        { meal: "lunch", diet_type_id: "d9", portions: 1 },
        { meal: "lunch", diet_type_id: "d15", portions: 3 },
        { meal: "dinner", diet_type_id: null, portions: 1 },
      ],
    }, [{ id: "d9" }, { id: "d15" }]);
    expect(rows.map((r) => r.dietId)).toEqual(["d9", "d15", null]);
    expect(rows[1].counts).toEqual({ breakfast: 2, lunch: 3, dinner: 0 });
    expect(rows[1].total).toBe(5);
    expect(totals).toEqual({ breakfast: 2, lunch: 4, dinner: 1 });
  });
});
