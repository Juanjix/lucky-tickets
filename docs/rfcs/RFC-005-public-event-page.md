# RFC-005 — Public Event Page

## Status

Complete. This is the first buyer-facing, unauthenticated page in Lucky
Ticket. It is read-only: no checkout, no order creation, no payment. See
"Deferred work" for what explicitly does not exist yet.

## Scope

An anonymous visitor can open a single published event's page and see its
name, description, date/time, venue, organizer, and public ticket types.
Nothing else changes: the RFC-004 organizer dashboard, its Server Actions,
its permissions, and its RLS policies are all untouched. RFC-005 adds a
new, narrow read path alongside the existing one — it does not modify or
relax it.

Before writing any code, the existing schema was inspected end to end:
RFC-002's `events`/`ticket_types`/`organizations` tables, their RLS
policies, RFC-004's migration and triggers, the generated `Database`
types, and RFC-004's own `queries.ts`/`actions.ts`. Nothing was missing —
`events.status`, `ticket_types.visibility`/`active`/`quantity`,
`organizations.timezone`/`currency`, and the sales-window columns already
carry everything this RFC needs. No table, column, or enum was added.

## Public URL

```text
/e/[organizationSlug]/[eventSlug]
```

Example: `/e/lucky-losers/lucky-losers-live`.

Organization-scoped, not event-UUID-based, matching `events_org_slug_key`
(RFC-002: slug uniqueness is scoped to an organization, not global) — the
URL structure mirrors that constraint exactly, rather than assuming global
slug uniqueness that doesn't actually exist. The route lives at a
top-level `e/` segment, entirely outside `dashboard/`, since it needs no
session or tenant resolution and never will (see architecture.md ADR-012
and "Directory responsibilities").

## Public Data Contract

Only the fields below ever reach the public page. Everything else on the
underlying rows (`organizations.id`/`logo_url`/`status`/timestamps,
`events.id`/`organization_id`/`created_at`/`updated_at`, ticket types'
`id`\* /`organization_id`/`event_id`/`max_per_order`/`sort_order`/
`active`/`visibility`/timestamps) is read only as needed to perform the
tenant-scoped joins and is never included in the response
(`src/features/events/public/types.ts`, `queries.ts`).

```text
organization:
  name
  slug
  timezone        (needed to render the event's date/time correctly)

event:
  name
  slug
  description
  venue_name
  venue_address
  starts_at
  ends_at
  capacity        (never rendered as a live "remaining" count - see "Ticket Availability")

ticket types (only ones passing the eligibility rule below):
  name
  description
  price (integer minor units + currency)
  sales_start_at
  sales_end_at
  availability (UPCOMING / AVAILABLE / ENDED - derived, not a column)
```

\* `ticket_types.id` is the one internal id kept in the DTO — RFC-005
excludes internal ids "unless operationally required", and RFC-006's
future ticket selection needs a stable identifier for "which ticket type".
It is never rendered as visible text.

## Public / Private Boundary

**Database.** A new migration
(`supabase/migrations/20260923000000_rfc_005_public_event_access.sql`)
adds three `to anon` SELECT policies:

- `events_select_public`: `status = 'PUBLISHED'`.
- `ticket_types_select_public`: `visibility = 'PUBLIC' and active and
quantity > 0 and` its event is `PUBLISHED`.
- `organizations_select_public`: the organization has at least one
  `PUBLISHED` event.

Each is a brand-new, independent permissive policy — Postgres OR's
permissive policies together, so these can only ever ADD visibility for
already-public data. They cannot weaken, replace, or interact with
RFC-002's `events_select_member` / `ticket_types_select_member` /
`organizations_select_member` (`to authenticated`), which are completely
unchanged. A DRAFT/FINISHED/CANCELLED/ARCHIVED event, a HIDDEN or inactive
ticket type, and an organization with zero published events all remain
exactly as invisible to `anon` as before this migration.

`organizations` additionally gets a real, database-enforced **column**
restriction — not just an application convention — because RFC-005 calls
this out specifically ("expose only the minimum necessary data" rather
than the whole row):

```sql
revoke select on public.organizations from anon;
grant select (id, name, slug, timezone, currency) on public.organizations to anon;
```

A real Supabase project's bootstrap privileges grant `anon` full
table-wide access by default (the same mechanism RFC-003 documented for
function `EXECUTE` grants) — RLS is normally the only gate on top of that.
The explicit `revoke` removes that blanket grant for `anon` specifically
(never for `authenticated`, whose full-column access for organization
members is untouched) before re-granting only `id` (needed because the
policy's own predicate reads `organizations.id`) plus the four columns the
public contract actually uses. An application bug that widens a
`.select("*")` on `organizations` cannot leak `logo_url`, `status`, or the
timestamps to `anon` — the database itself refuses the column, not just
the application's own code review.

**Application.** `src/features/events/public/queries.ts` is the only
place allowed to import `src/lib/supabase/public.ts`, and its one export,
`getPublicEvent(organizationSlug, eventSlug)`, maps every database row
into the narrow DTOs in `types.ts` before returning — organizer-facing
code (`src/features/events/queries.ts`, `Tables<"events">`) is never
reused here, and the public page never receives a raw database row.

**Not found, uniformly.** `getPublicEvent` returns `null` for a
nonexistent organization slug, a nonexistent event slug, an event that
exists but isn't `PUBLISHED`, and an event that exists under a different
organization than the URL's — the page (`src/app/e/[organizationSlug]/[eventSlug]/page.tsx`)
calls Next's `notFound()` for every one of these identically. No case is
distinguishable from any other by the visitor, extending the same
existence-hiding principle RFC-003's `requireOrganizationMembership`
already established for the dashboard (ADR-010) to the public path.

## RLS / Database Strategy

The smallest safe mechanism was chosen: three additional RLS policies plus
one column-privilege narrowing, no new function, no view, no
`SECURITY DEFINER` anywhere. Every policy above is `security invoker` by
construction (they're plain RLS policies, not functions — there's no
elevated-privilege mode to justify or avoid).

The architectural decision that makes this simple is
`src/lib/supabase/public.ts`: a Supabase client built with plain
`@supabase/supabase-js` (not `@supabase/ssr`) that never reads the
visitor's cookies and disables session persistence entirely. It always
authenticates as `anon` at the database, for every visitor, whether
they're logged out, logged into their own organization, or logged into a
completely unrelated one. This is why the new policies only ever need to
say `to anon` — an authenticated request is simply never made against the
public route, so there is no scenario to reason about where `authenticated`
needs new privileges here at all. See architecture.md ADR-012 for the full
rationale against the alternative (reusing the cookie-forwarding server
client and adding `to authenticated` policies too).

**Mutation is not granted.** No INSERT/UPDATE/DELETE policy exists for
`anon` on any of the three tables. `anon` does hold table-level
INSERT/UPDATE/DELETE _privileges_ (Supabase's default privileges apply the
same "grant everything, let RLS gate it" posture to every command, not
just SELECT) — but with zero matching RLS policies for those commands,
Postgres denies them. The _shape_ of that denial differs by command,
verified empirically in `rfc_005_public_event_access.test.sql`: an INSERT
whose `WITH CHECK` fails throws `42501` (a rejected new row has nowhere
else to go), while an UPDATE with no matching `USING` clause just excludes
the row from the update — it "succeeds" with zero rows affected, the same
asymmetry RFC-004 first documented for cross-role `authenticated` updates.
Both cases are tested explicitly (tests 16–18) rather than assumed.

## Ticket Availability

Centralized in `src/features/events/public/availability.ts`
(`deriveTicketAvailability`), a pure function called once per ticket type
in `queries.ts` — no component computes its own date logic.

```text
sales_start_at > now   → UPCOMING
sales_end_at <= now    → ENDED
otherwise              → AVAILABLE
```

This is purely a display label. `sales_start_at`/`sales_end_at` are never
mutated, and no derived state is persisted anywhere. Availability is
computed independently of the RLS eligibility predicate (visibility/
active/quantity/event-status) — a ticket type can be publicly _visible_
and still show as UPCOMING or ENDED; those are different questions.

**No fake inventory.** `ticket_types.quantity` is RFC-004's _configured_
inventory, not RFC-006's future live availability accounting — the public
page never displays "X tickets remaining", "Only 3 left", "Selling fast",
or "Sold out". The only quantities used are the three real, provable
states above; `event.capacity` is carried in the DTO for future RFC-006
use but is not rendered as a live count today.

## Timezone

Every organization already carries an IANA `timezone` (RFC-002, default
`America/Argentina/Buenos_Aires`). `src/features/events/public/format.ts`
passes it explicitly to `Intl.DateTimeFormat` as `timeZone` for every
date/time shown on the page, so an event's start time renders correctly
for every visitor regardless of their own device's timezone or the
server's. The default locale is `es-AR` (matching RFC-002's own ARS/Buenos
Aires defaults) but is an explicit, overridable parameter on every
formatter, not a hardcoded assumption — a future multi-locale RFC can pass
a different one without touching this module's structure. Stored
timestamps are never altered; only the display string is computed.

## Metadata

`generateMetadata` (`src/app/e/[organizationSlug]/[eventSlug]/page.tsx`)
calls the same `getPublicEvent` the page itself calls (deduplicated within
one request via React's `cache()` — see "Caching" below) and sets `title`
and `description` from the public event/organization. For a `null` result
(nonexistent, private, or wrong-organization event), metadata falls back
to the generic site title with no event-specific text at all — nothing
about the hidden event is ever present in the response, including its
metadata. Open Graph images, `schema.org` Event JSON-LD, and social-share
cards are intentionally not implemented — the structure (one function,
one data source) is ready for a future RFC to extend without rework.

## Caching

No cross-request caching or ISR/`revalidate` is configured anywhere on
this route — every request re-runs the query from scratch, so an
organizer's edit (a price change, adding a ticket type, changing the
venue) is reflected on the very next page load. The RFC is explicit that
correctness matters more than performance here for the MVP, and no
Server Action from RFC-004 needs to know about or invalidate anything
this route caches, because nothing is cached across requests.

The only memoization is React's `cache()` wrapping `getPublicEvent` itself
(`src/features/events/public/queries.ts`), which deduplicates the _within
a single request_ call made by both `generateMetadata` and the page
component — without it, one page view would run the same three queries
twice. This has no correctness implications (both callers are in the same
request, seeing the same data) and no invalidation to reason about (the
memoization doesn't outlive the request).

## Routes

- `src/app/e/[organizationSlug]/[eventSlug]/page.tsx` — the public page. A
  Server Component; no client-side data fetching. No authentication check
  of any kind — there is nothing to check, since `getPublicEvent` always
  reads as `anon` regardless of who's browsing.
- No changes to any `dashboard/` route.

## Server Actions

None. RFC-005 adds no Server Action — this is a pure read path. The
`[ Select ]` control on each ticket type renders as a disabled `<button>`
(`src/features/events/public/components/ticket-type-list.tsx`), not a
link or a client handler, so there is nothing for RFC-006 to have to
un-wire — only to enable.

## Security

- No service-role key anywhere in this RFC's code.
- RLS is not disabled anywhere; no existing policy was weakened, dropped,
  or replaced.
- `organizationSlug`/`eventSlug` are taken from the URL and used only as
  query filters (`.eq(...)`) resolved against the database — never trusted
  as proof that a matching, public record exists.
- Currency always comes from the ticket type's own `currency` column
  (already trusted, set server-side at creation in RFC-004) — never a
  route or query parameter.
- Authenticated users from another tenant gain no additional access
  through this path: the public route's client never carries their
  session, so their own membership is never consulted, and the `anon`
  policies grant nothing beyond what any other visitor already sees.

## Tests

`supabase/tests/database/rfc_005_public_event_access.test.sql` — 18 new
pgTAP assertions:

1. `anon` can read a PUBLISHED event through the public boundary.
2. `anon` cannot read a DRAFT event.
3. `anon` cannot read a FINISHED event through normal public access.
4. `anon` cannot read a CANCELLED event.
5. `anon` cannot read an ARCHIVED event.
6. `anon` can read a PUBLIC/active ticket type for a published event.
7. `anon` cannot read a HIDDEN ticket type.
8. `anon` cannot read an inactive ticket type.
9. A PUBLIC/active ticket type on a DRAFT event is not publicly visible —
   the event's own status gates it, not just the ticket type's own flags.
10. `anon` can read the organization row for an org with a published
    event.
11. `anon` cannot read an organization with zero published events (no
    enumeration of private orgs).
12. `anon` can read `organizations.name`/`slug`.
13. `anon` cannot read `organizations.logo_url` — column-level privilege
    denies it even though the row itself is visible (`42501`).
14. `anon` cannot read `organizations.status`.
15. A published event's slug under the _wrong_ organization returns no
    public record (composite-key confusion is impossible, not just
    unlikely).
16. `anon` cannot insert an event (`42501`).
17. `anon`'s UPDATE attempt on a published event does not throw...
18. ...but it also affects zero rows — verified by re-reading the row as
    the organization's own OWNER and confirming it is still `PUBLISHED`,
    not the value `anon` attempted to set.

A quantity-of-zero "sold out, otherwise-eligible" ticket type is _not_
fixtured — RFC-002's own `ticket_types_quantity_positive` CHECK constraint
already makes `quantity = 0` an unreachable state for any row that exists
at all, so the RLS clause's `quantity > 0` is defense in depth for if that
constraint is ever relaxed, not something this suite can exercise today.

**Regression baseline.** RFC-002 (22), RFC-003 (14), and RFC-004 (20) were
re-run unchanged alongside the new suite: **74/74 pgTAP assertions pass**,
verified twice against a from-scratch-rebuilt database for determinism.
RFC-002's own pre-existing anonymous-access tests ("anonymous cannot read
any events/organizations") still pass unmodified — their fixtures are
`DRAFT`, so RFC-005's new `anon` visibility (scoped to `PUBLISHED` only)
never applies to them.

## Application Tests / Pure Logic

`deriveTicketAvailability` and the date formatters are already pure,
dependency-free functions taking their inputs as parameters (including an
optional `now`/`locale`) specifically so they're testable without a
framework. The project has no test runner configured yet for application
code (only the pgTAP suite for the database), so no new dependency was
introduced solely to unit-test these — consistent with the RFC's own
instruction not to add a testing framework just for a few small helpers.

## Deferred Work

Everything explicitly out of scope for RFC-005: checkout, shopping cart,
order/order-item creation, ticket holds, inventory reservation, Mercado
Pago, payment intents/preferences, payment webhooks, a buyer account,
ticket issuance, QR codes, email delivery, check-in, guest lists, discount
codes, ticket transfer/resale, refunds, billing, settlements, promoters,
merchandising, audience CRM, analytics, custom domains, an image upload
system, seat maps, and Open Graph images/structured data for social
sharing. These arrive in RFC-006 and later.
