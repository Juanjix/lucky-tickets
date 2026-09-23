/**
 * Money helpers for the minor-units convention RFC-002 established (see
 * docs/database.md "Money representation"): every monetary column is an
 * integer count of minor units (e.g. ARS $12,500.50 is stored as
 * 1250050), never a float. These are the only place that conversion
 * happens - forms collect a major-unit amount from the organizer (what a
 * human types, e.g. "15000.00"), `toMinorUnits` converts it to what the
 * database expects, and `fromMinorUnits`/`formatMoney` convert back for
 * display. Never pass a value already read from the database (already
 * minor units) into `toMinorUnits`.
 */

export function toMinorUnits(amountMajor: number): number {
  return Math.round(amountMajor * 100);
}

export function fromMinorUnits(amountMinor: number): number {
  return amountMinor / 100;
}

/** Formats integer minor units as a localized currency string, e.g. formatMoney(1500050, "ARS") -> "ARS 15.000,50" (exact formatting depends on the runtime's default locale). */
export function formatMoney(amountMinor: number, currency: string): string {
  return new Intl.NumberFormat(undefined, {
    style: "currency",
    currency,
  }).format(fromMinorUnits(amountMinor));
}
