import { describe, expect, it } from "vitest";
import { programLines } from "./program";

describe("programLines", () => {
  it("keeps one line per piece, author and work apart", () => {
    expect(
      programLines([
        { composer: "Antonín Dvořák", work: "Symfonie č. 9 e moll" },
        { composer: "Leoš Janáček", work: "Taras Bulba" },
      ]),
    ).toEqual([
      { author: "Antonín Dvořák", work: "Symfonie č. 9 e moll" },
      { author: "Leoš Janáček", work: "Taras Bulba" },
    ]);
  });

  it("reads each lane's own field names", () => {
    expect(
      programLines([
        { author: "Anton Pavlovič Čechov", play: "Racek" },
        { director: "Andrej Tarkovskij", film: "Stalker" },
      ]),
    ).toEqual([
      { author: "Anton Pavlovič Čechov", work: "Racek" },
      { author: "Andrej Tarkovskij", work: "Stalker" },
    ]);
  });

  it("keeps a half-filled entry and trims the text", () => {
    expect(programLines([{ work: "  Requiem  " }, { composer: "Arvo Pärt" }])).toEqual([
      { author: null, work: "Requiem" },
      { author: "Arvo Pärt", work: null },
    ]);
  });

  it("drops entries with nothing printable and handles no programme at all", () => {
    expect(programLines([{ composer: "   " }, { note: "bis" }])).toEqual([]);
    expect(programLines(null)).toEqual([]);
  });
});
