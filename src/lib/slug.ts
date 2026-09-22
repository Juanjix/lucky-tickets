/**
 * Normalizes free text (an organization name, later an event name) into the
 * lowercase, hyphenated form the database's slug CHECK constraints require
 * (see `organizations_slug_format` / `events_slug_format` in the RFC-002
 * migration: `^[a-z0-9]+(-[a-z0-9]+)*$`).
 *
 * This is a pure function used to produce a *candidate* slug — it never
 * guarantees uniqueness on its own. Uniqueness is enforced by the database
 * (a unique index) and collisions are resolved server-side by
 * `create_organization()` (see the RFC-003 migration), which appends a
 * numeric suffix and retries. Never trust a slug computed on the client for
 * anything beyond a cosmetic preview.
 */
export function slugify(input: string): string {
  return input
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "") // strip accents/diacritics (á, ñ, ...)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-");
}
