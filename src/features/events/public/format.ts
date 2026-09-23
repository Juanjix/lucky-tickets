/**
 * Buyer-facing date/time formatting for the public event page (RFC-005).
 *
 * Organizations already carry an IANA `timezone` (RFC-002, defaulting to
 * "America/Argentina/Buenos_Aires") - every formatter here takes it
 * explicitly and passes it to `Intl.DateTimeFormat` as `timeZone`, so an
 * event's date/time renders correctly for every visitor regardless of
 * their own device's timezone, rather than "blindly" using the browser or
 * server's local time (RFC-005 "Event date/time"). Stored timestamps are
 * never touched - these functions only produce display strings.
 *
 * The default locale is Argentina-Spanish, matching this product's actual
 * market (RFC-002 already defaults currency to ARS and timezone to Buenos
 * Aires) - but every function accepts an explicit `locale` override, so
 * this is a default, not an architectural lock-in, for whenever RFC-00X
 * adds real multi-locale support.
 */

const DEFAULT_LOCALE = "es-AR";

/** e.g. "sábado, 10 de octubre" */
export function formatEventDate(
  iso: string,
  timezone: string,
  locale: string = DEFAULT_LOCALE,
): string {
  return new Intl.DateTimeFormat(locale, {
    timeZone: timezone,
    weekday: "long",
    day: "numeric",
    month: "long",
  }).format(new Date(iso));
}

/** e.g. "21:00" */
export function formatEventTime(
  iso: string,
  timezone: string,
  locale: string = DEFAULT_LOCALE,
): string {
  return new Intl.DateTimeFormat(locale, {
    timeZone: timezone,
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(iso));
}
