/** Mirrors `apps/api/tests/test_program_links.py::test_folding_canon` — the
 * same fixtures must fold to the same keys on both sides. */

import { describe, expect, it } from "vitest";
import { programKey, programQuery } from "./programKey";

describe("programKey", () => {
  it("folds diacritics, case and punctuation away", () => {
    expect(programKey("Antonín Dvořák", "Symfonie č. 9 e moll")).toBe(
      "antonin dvorak|symfonie c 9 e moll",
    );
    expect(programKey("ANTONIN  DVORAK", "  symfonie   c9 e-moll  ")).toBe(
      "antonin dvorak|symfonie c9 e moll",
    );
  });

  it("keeps a half-known piece lookupable", () => {
    expect(programKey(null, "Requiem")).toBe("|requiem");
    expect(programKey("Arvo Pärt", null)).toBe("arvo part|");
  });

  it("returns null when nothing printable survives", () => {
    expect(programKey("  ", "…")).toBeNull();
    expect(programKey(null, null)).toBeNull();
  });
});

describe("programQuery", () => {
  it("joins the halves it has", () => {
    expect(programQuery("Leoš Janáček", "Taras Bulba")).toBe("Leoš Janáček Taras Bulba");
    expect(programQuery(null, "Requiem")).toBe("Requiem");
  });
});
