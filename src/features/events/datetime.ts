/**
 * Converts an ISO timestamp (as read from the database) to the value a
 * `<input type="datetime-local">` element expects ("YYYY-MM-DDTHH:mm", in
 * the browser's local time zone), for prefilling an edit form.
 * `fromDateTimeLocalValue` below does the reverse, for submission. Shared
 * by every event/ticket-type form that edits a timestamp field.
 */
export function toDateTimeLocalValue(iso: string | null | undefined): string {
  if (!iso) {
    return "";
  }

  const date = new Date(iso);

  if (Number.isNaN(date.getTime())) {
    return "";
  }

  const pad = (value: number) => String(value).padStart(2, "0");

  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/**
 * The reverse of `toDateTimeLocalValue`, and the only place this
 * conversion should happen: per the HTML spec, `new Date(...)` parses a
 * timezone-less "YYYY-MM-DDTHH:mm" string (exactly what a
 * `datetime-local` input holds) as the LOCAL time of whatever JS engine
 * runs this call. That's only correct when it runs in the organizer's own
 * browser - calling this on the server would silently reinterpret their
 * chosen wall-clock time in the server's timezone instead. So every form
 * that collects a datetime-local value converts it to a real UTC ISO
 * string here, client-side, in its onSubmit handler, before ever calling
 * a Server Action - never inside a Zod schema (which also runs
 * server-side on re-validation) and never inside an action itself.
 */
export function fromDateTimeLocalValue(value: string): string {
  return new Date(value).toISOString();
}
