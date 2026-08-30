/** A listbox dropdown that replaces the native `<select>`.
 *
 * Chrome hands a native select popup to the OS as its own window, and on the
 * planner's desktop (Wayland, two 4K panels side by side) that window lands
 * far away from the control it belongs to. An in-DOM listbox is positioned
 * by the layout itself, so it can only ever open next to its trigger — and
 * it picks up the app's own theme tokens instead of the GTK ones.
 *
 * Keyboard model is roving focus: opening moves focus onto the selected row,
 * arrows walk the rows, Enter picks, Esc returns focus to the trigger.
 */

import type { KeyboardEvent } from "react";
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import styles from "./Select.module.css";

export interface SelectOption {
  value: string;
  label: string;
  /** Heading this option sits under. Consecutive options sharing a heading
   * render as one group, the way `<optgroup>` did. */
  group?: string;
}

interface SelectProps {
  /** The picked option's value; `""` means "no filter". */
  value: string;
  options: readonly SelectOption[];
  /** Trigger text while nothing is picked, and the label of the row that
   * clears the filter. */
  placeholder: string;
  onChange: (value: string) => void;
}

interface Row extends SelectOption {
  index: number;
}

interface Section {
  label: string | undefined;
  rows: Row[];
}

/** Keep in sync with `.list { max-height }` — only used to decide the flip. */
const MAX_LIST_HEIGHT_PX = 288;

const OPEN_KEYS = ["ArrowDown", "ArrowUp", "Enter", " "];

export function Select({ value, options, placeholder, onChange }: SelectProps) {
  const [open, setOpen] = useState(false);
  const [dropUp, setDropUp] = useState(false);
  const [activeIndex, setActiveIndex] = useState(0);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const optionRefs = useRef<(HTMLDivElement | null)[]>([]);
  const listId = useId();

  // The placeholder is a real row: picking it clears the filter.
  const rows = useMemo<Row[]>(
    () =>
      [{ value: "", label: placeholder }, ...options].map((option, index) => ({
        ...option,
        index,
      })),
    [options, placeholder],
  );
  const sections = useMemo<Section[]>(() => {
    const grouped: Section[] = [];
    for (const row of rows) {
      const last = grouped.at(-1);
      if (last !== undefined && last.label === row.group) {
        last.rows.push(row);
      } else {
        grouped.push({ label: row.group, rows: [row] });
      }
    }
    return grouped;
  }, [rows]);

  const selectedIndex = Math.max(
    0,
    rows.findIndex((row) => row.value === value),
  );
  const triggerLabel = rows[selectedIndex]?.label ?? placeholder;

  const openList = useCallback(() => {
    const rect = rootRef.current?.getBoundingClientRect();
    const below = rect === undefined ? Number.POSITIVE_INFINITY : window.innerHeight - rect.bottom;
    setDropUp(rect !== undefined && below < MAX_LIST_HEIGHT_PX && rect.top > below);
    setActiveIndex(selectedIndex);
    setOpen(true);
  }, [selectedIndex]);

  const close = useCallback((returnFocus: boolean) => {
    setOpen(false);
    if (returnFocus) {
      triggerRef.current?.focus();
    }
  }, []);

  const commit = useCallback(
    (index: number) => {
      const row = rows[index];
      close(true);
      if (row !== undefined && row.value !== value) {
        onChange(row.value);
      }
    },
    [rows, value, onChange, close],
  );

  // A pointer landing anywhere else dismisses the list, exactly like the
  // native popup did.
  useEffect(() => {
    if (!open) {
      return;
    }
    const onPointerDown = (event: PointerEvent) => {
      if (rootRef.current !== null && !rootRef.current.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("pointerdown", onPointerDown);
    return () => document.removeEventListener("pointerdown", onPointerDown);
  }, [open]);

  // Roving focus: the active row owns the caret, which also scrolls it into
  // view and keeps screen readers on the right item.
  useEffect(() => {
    if (open) {
      optionRefs.current[activeIndex]?.focus();
    }
  }, [open, activeIndex]);

  const onTriggerKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (!open && OPEN_KEYS.includes(event.key)) {
      event.preventDefault();
      openList();
    }
  };

  const onOptionKeyDown = (event: KeyboardEvent<HTMLDivElement>, index: number) => {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        setActiveIndex(Math.min(index + 1, rows.length - 1));
        break;
      case "ArrowUp":
        event.preventDefault();
        setActiveIndex(Math.max(index - 1, 0));
        break;
      case "Home":
        event.preventDefault();
        setActiveIndex(0);
        break;
      case "End":
        event.preventDefault();
        setActiveIndex(rows.length - 1);
        break;
      case "Enter":
      case " ":
        event.preventDefault();
        commit(index);
        break;
      case "Escape":
        event.preventDefault();
        close(true);
        break;
      // Tab leaves the whole control: close, then let focus travel on from
      // the trigger rather than from a row that is about to disappear.
      case "Tab":
        close(true);
        break;
      default:
        break;
    }
  };

  return (
    <div ref={rootRef} className={styles.root}>
      <button
        ref={triggerRef}
        type="button"
        role="combobox"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={listId}
        className={`${styles.trigger} ${value === "" ? "" : styles.triggerActive}`}
        onClick={() => (open ? close(false) : openList())}
        onKeyDown={onTriggerKeyDown}
      >
        <span className={styles.label}>{triggerLabel}</span>
        <span className={styles.chevron} aria-hidden="true">
          ▾
        </span>
      </button>
      {open && (
        <div id={listId} role="listbox" className={`${styles.list} ${dropUp ? styles.listUp : ""}`}>
          {sections.map((section) => (
            // biome-ignore lint/a11y/useSemanticElements: a <fieldset> cannot live inside a listbox
            <div
              key={section.label ?? "ungrouped"}
              role="group"
              {...(section.label === undefined ? {} : { "aria-label": section.label })}
            >
              {section.label !== undefined && (
                <div className={styles.groupHeading} aria-hidden="true">
                  {section.label}
                </div>
              )}
              {section.rows.map((row) => (
                <div
                  key={row.value}
                  ref={(element) => {
                    optionRefs.current[row.index] = element;
                  }}
                  role="option"
                  tabIndex={-1}
                  aria-selected={row.index === selectedIndex}
                  className={`${styles.option} ${row.index === selectedIndex ? styles.selected : ""}`}
                  onClick={() => commit(row.index)}
                  onKeyDown={(event) => onOptionKeyDown(event, row.index)}
                >
                  {row.label}
                </div>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
