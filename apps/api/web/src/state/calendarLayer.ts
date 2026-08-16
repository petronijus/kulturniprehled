/** Visibility of the shared-calendar layer in the grid.
 *
 * Purely presentational: hiding the layer drops the chips and the blocked-day
 * hatching, but the rule engine keeps running on the real blocked days, so a
 * pick on a vacation day is still reported as a violation. The choice sticks
 * across visits.
 */

import { useCallback, useState } from "react";

const KEY = "kp.calendarVisible";

function stored(): boolean {
  // Default on — the calendar is the reason the layer exists.
  return localStorage.getItem(KEY) !== "off";
}

export function useCalendarVisible(): [boolean, () => void] {
  const [visible, setVisible] = useState<boolean>(stored);

  const toggle = useCallback(() => {
    setVisible((current) => {
      const next = !current;
      localStorage.setItem(KEY, next ? "on" : "off");
      return next;
    });
  }, []);

  return [visible, toggle];
}
