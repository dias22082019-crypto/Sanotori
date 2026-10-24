import { describe, expect, it } from "vitest";
import { balanceAfter, formatQty, parseQuantity, stockLevel } from "./inventory";

describe("inventory", () => {
  it("classifies stock level against the minimum", () => {
    expect(stockLevel({ quantity: "0.000", min_quantity: 10 })).toBe("out");
    expect(stockLevel({ quantity: 10, min_quantity: "10.000" })).toBe("low");
    expect(stockLevel({ quantity: 11, min_quantity: 10 })).toBe("ok");
    expect(stockLevel({ quantity: 3, min_quantity: 0 })).toBe("ok");
  });
  it("parses quantities with comma and up to 3 decimals", () => {
    expect(parseQuantity("2,5")).toBe(2.5);
    expect(parseQuantity(" 1 200 ")).toBe(1200);
    expect(parseQuantity("0.125")).toBe(0.125);
    expect(parseQuantity("0.1255")).toBeNull();
    expect(parseQuantity("0")).toBeNull();
    expect(parseQuantity("0", true)).toBe(0);
    expect(parseQuantity("-3")).toBeNull();
    expect(parseQuantity("abc")).toBeNull();
  });
  it("computes the balance after a movement", () => {
    expect(balanceAfter("receipt", 10, 5)).toBe(15);
    expect(balanceAfter("issue", 10, 2.5)).toBe(7.5);
    expect(balanceAfter("writeoff", 10, 12)).toBe(-2);
    expect(balanceAfter("adjustment", 10, 8)).toBe(8);
    expect(balanceAfter("issue", 0.3, 0.1)).toBe(0.2);
  });
  it("formats quantities without trailing zeros", () => {
    expect(formatQty("12.000")).toBe("12");
    expect(formatQty("2.500")).toBe("2,5");
  });
});
