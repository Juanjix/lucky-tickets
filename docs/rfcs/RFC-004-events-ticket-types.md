# RFC-004 — Events & Ticket Types

**Status:** Implemented, pending local Supabase validation. Builds on
RFC-001 (Next.js/Supabase foundation), RFC-002 (database schema, tenant
isolation, RLS), and RFC-003 (authentication, organizations, tenant
routing) without modifying any of their migrations.

## Goals

Implement the first real Lucky Ticket business domain for the internal
organizer dashboard: an authenticated organization member with sufficient
permissions can view an organization's events, create a DRAFT event, view
and edit it, manage its ticket types, and publish it once it meets a
centralized set of invariants.

Explicitly not in scope (deferred to later RFCs): the public event page,
public event discovery, checkout, Mercado Pago, payment webhooks, orders,
order items, ticket issuance, QR codes, check-in, guest lists, billing,
settlements, promoters, merchandising, audience CRM, email campaigns,
advanced analytics, discount codes, ticket transfer/resale, seat maps, and
native applications. See "Deferred" below.

## Domain model

```text
Organization
   │
   ├── Event (DRAFT | PUBLISHED | FINISHED | CANCELLED | ARCHIVED)
   │     │
   │     └── Ticket Types (General, Early Bird, VIP, ...)
   │
   └── Event
```

**No new table and no new column.** RFC-002 already created
`public.events` and `public.ticket_types` in full — every field this RFC
needs (`name`, `slug`, `description`, `venue_name`, `venue_address`,
`starts_at`, `ends_at`, `capacity`, `status` on events;
`unit_price_amount`, `currency`, `quantity`, `visibility`,
`sales_start_at`/`sales_end_at`, `sort_order`, `active` on ticket types) —
and their RLS policies (`events_select_member`, `events_insert_operator`,
`events_update_operator`, `ticket_types_select_member`,
`ticket_types_insert_operator`, `ticket_types_update_operator`,
`ticket_types_delete_operator`), already matching RFC-004's
OWNER/ADMIN/PRODUCER-write, any-member-read permission model exactly. This
was confirmed by inspecting the RFC-002 migration and generated database
types before writing any RFC-004 code, per this RFC's own explicit
instruction not to blindly create new tables. `events.venue_city`,
`events.cover_image_url`, `events.doors_open_at`, and
`ticket_types.max_per_order` also already exist and remain available for
later RFCs; this RFC's forms don't expose them, since RFC-004 only asks for
the fields it lists and "do not add fields merely because they might be
useful someday" cuts the other way too — not adding UI for a field is not
the same as adding an unnecessary column.

## Event lifecycle

Only the five states RFC-002 already persists are used:
`DRAFT` → `PUBLISHED` → `FINISHED` / `CANCELLED` / `ARCHIVED`. RFC-004
itself only produces `DRAFT` (on creation) and `PUBLISHED` (via
`publishEventAction`); `FINISHED`/`CANCELLED`/`ARCHIVED` remain reachable
in the schema for later RFCs but have no UI path yet. No derived UI state
(`UPCOMING`, `ON_SALE`, `SOLD_OUT`, `PAST`) is persisted anywhere — those
remain concepts to compute at query time from `starts_at`/`sales_start_at`/
`sales_end_at`/inventory/status, exactly as RFC-002's schema comment on
`events` already specifies.

## Event creation & slugs

`createEventAction` (`src/features/events/actions.ts`) requires only a
name and a start date — the minimum RFC-004 asks for, and the minimum the
database's `starts_at not null` constraint actually requires. Venue,
description, capacity, and ticket types are all configured afterward from
the event management page:

```text
Create Event (name + start date)
    ↓
DRAFT
    ↓
Configure details (venue, description, capacity, end date)
    ↓
Configure ticket types
    ↓
Publish
```

The slug is generated server-side from the name via the existing
`slugify()` (`src/lib/slug.ts` — its own docstring already anticipated
event names, not just organization names) and is never trusted from the
client. Uniqueness is organization-scoped
(`events_org_slug_key unique (organization_id, slug)`, RFC-002), not
global — two different organizations may each have their own event at
slug `opening-night`. Collisions are resolved by retrying with a numeric
suffix (`-2`, `-3`, ...), up to 5 attempts, in `createEventAction` itself.
Unlike organization creation (RFC-003), this doesn't need a database
function for atomicity: creating an event is a single-table insert, so the
retry loop lives in application code.

## Event capacity vs. ticket inventory

RFC-004 asks that the sum of configured ticket-type inventory never exceed
an event's overall capacity, when capacity is set. This spans two tables
and can change from either side (adding/growing a ticket type, or lowering
an event's capacity after tickets already exist), so it can't be expressed
as a single-table `CHECK` constraint. The new migration
(`supabase/migrations/20260922000000_rfc_004_events_ticket_types.sql`)
adds `check_event_ticket_capacity(event_id)` plus two triggers —
`ticket_types_capacity_check` (fires on ticket-type insert/update) and
`events_capacity_check` (fires when an event's capacity changes) — that
both call the same shared check function, so the rule is identical
regardless of which side of the relationship changed. Only `active`
ticket types count toward allocated inventory; a deactivated one no longer
does. This is intentionally a real database constraint, not just a form
validation: even a request that bypassed the Server Action entirely would
still be rejected (SQLSTATE `23514`). RFC-006 (inventory
reservation/holds) is not implemented and not blocked by this — the
trigger only checks configured quantities, never touches actual
availability.

## Event publication

Publishing is a server-side operation with centralized validation, not an
unrestricted status dropdown. `getPublishIssues()`
(`src/features/events/publish-rules.ts`) is the single source of truth
`publishEventAction` checks before ever attempting the database update,
and what RFC-005/RFC-006 are expected to import and extend rather than
re-implement. It checks:

- the event has a name and a start date (already guaranteed
  unconditionally by RFC-002's `NOT NULL`/`events_name_not_blank`
  constraints — restated here so the organizer gets one clear message
  covering everything, not because the database wouldn't already prevent
  the alternative);
- the event has a venue (`venue_name`);
- at least one `PUBLIC`, `active`, positive-quantity ticket type exists
  (a `HIDDEN` or deactivated ticket type does not count as "sellable");
- every sellable ticket type's price and quantity are valid (already
  guaranteed unconditionally by RFC-002's CHECK constraints on
  `ticket_types` — restated for the same reason as above);
- configured ticket inventory doesn't exceed capacity, when set.

A deliberately minimal, matching backstop also lives at the database
layer: `enforce_event_publish_invariants()` (same migration) rejects any
write that would leave `status = 'PUBLISHED'` without a configured venue
or without at least one sellable ticket type — the two invariants that
aren't already unconditionally guaranteed by an existing column
constraint. This is defense in depth in the same shape RFC-002/RFC-003
already established for authorization (RLS plus an independent
application-level check); it is not a generic workflow/state-machine
framework — just two narrowly-scoped triggers.

## Ticket Types

Reuses RFC-002's `ticket_types` table and `ticket_visibility` enum
(`PUBLIC`, `HIDDEN`) unchanged. Money is never floating point: the
organizer enters a price in major units (e.g. `15000.00`) in
`TicketTypeForm`, and `toMinorUnits()`/`fromMinorUnits()`
(`src/lib/money.ts`, new in this RFC) convert to/from the integer minor
units `unit_price_amount` actually stores, matching RFC-002's existing
convention exactly (`docs/database.md` "Money representation"). Currency
always follows the organization's own `currency` column
(`organizations.currency`) — never a client-supplied value, and never a
per-ticket-type choice exposed in the UI, even though the column exists
for future flexibility.

**Sales windows.** `sales_start_at`/`sales_end_at` are exposed in the
form. RFC-004 asks for a _strict_ `sales_end_at > sales_start_at`; RFC-002's
own `ticket_types_sales_window_order` CHECK constraint (unchanged — this
RFC does not modify the RFC-002 migration) allows equality
(`sales_start_at <= sales_end_at`). Rather than weaken or duplicate that
constraint, the stricter rule is enforced at the application layer
(`createTicketTypeSchema`/`updateTicketTypeSchema` in
`src/features/events/schemas.ts`, via a Zod `superRefine`); the database
constraint still stands as a backstop for anything that bypassed the form.
No inventory reservation, hold, or automatic lifecycle job is implemented
— "on sale" remains a concept to derive later, per RFC-004's explicit
scope.

## Permissions

Reuses RFC-002's RLS role matrix directly; no new role or policy was
needed.

- **OWNER / ADMIN / PRODUCER** — create, edit, and publish events; create,
  edit, and remove ticket types (`EVENT_MANAGER_ROLES` in
  `src/features/events/permissions.ts`).
- **DOOR_STAFF** — no event-configuration mutations (nothing in RFC-004
  grants DOOR_STAFF write access to `events`/`ticket_types`; RFC-002 never
  did either).
- **VIEWER** — read-only, same scope as PRODUCER minus write.

`requireEventManager()` wraps RFC-003's `requireOrganizationRole` with
`EVENT_MANAGER_ROLES` and is called first, before any other logic, by
every event/ticket-type Server Action and by the `/events/new` page (so
DOOR_STAFF/VIEWER are redirected away from that screen entirely, not just
denied on submit — "hiding a button is not authorization" cuts both ways).
A role is never read from client input; every check re-derives the
caller's real membership row server-side.

## Multi-tenant security

Every Server Action resolves `organizationSlug` from the URL through
`requireOrganizationMembership`/`requireEventManager` to get a trusted
`organization.id`, then scopes every query and mutation with an explicit
`.eq("organization_id", organization.id)` — never trusting an `eventId` or
`ticketTypeId` from a request body beyond that filter. This is defense in
depth on top of RFC-002's own tenant-consistency mechanism: `ticket_types`
carries a composite foreign key to `events(organization_id, id)`
(`ticket_types_org_event_fk`), making it a schema-level impossibility for
a ticket type to reference an event in a different organization, and RLS
(`events_select_member`/`events_update_operator`/etc.) makes a
cross-organization row invisible or unwritable regardless of what the
application layer does. No service-role key is used anywhere in this RFC.

## Routes

```text
/dashboard/[organizationSlug]/events            list + "Create event"
/dashboard/[organizationSlug]/events/new        create form
/dashboard/[organizationSlug]/events/[eventId]  details, ticket types, publish
```

No separate `/edit` route: the management page keeps event details,
ticket types, and publication status as three sections on one page,
preferring a simple architecture over more routes, per RFC-004's own
guidance. The dashboard layout
(`src/app/dashboard/[organizationSlug]/layout.tsx`) gained two navigation
links (Dashboard, Events) alongside the existing organization
name/switcher and sign-out button — not a redesign.

## Server Actions

All in `src/features/events/actions.ts`, all following the same shape:
authenticate + resolve membership + check role (`requireEventManager`),
validate input (Zod), perform a tenant-scoped database operation, handle
expected database error codes, `revalidatePath` the affected page(s).

- `createEventAction` — creates a DRAFT event.
- `updateEventAction` — updates an event's own details.
- `createTicketTypeAction` / `updateTicketTypeAction` /
  `deleteTicketTypeAction` — manage ticket types. `deleteTicketTypeAction`
  already handles the `23503` (foreign-key restrict) error RFC-002's
  `order_items_org_ticket_type_fk` will start raising once RFC-006
  introduces real orders — nothing here needs to change when that
  happens.
- `publishEventAction` — validates via `getPublishIssues()`, then flips
  `status` to `PUBLISHED` and sets `published_at`.

## Queries

`src/features/events/queries.ts`: `listOrganizationEvents`,
`getOrganizationEvent`, `getEventTicketTypes` — each takes an
already-resolved `organizationId`, filters explicitly by it in addition to
relying on RLS, and lets PostgreSQL do the filtering rather than fetching
everything and filtering in application memory.

## Database changes

One new migration,
`supabase/migrations/20260922000000_rfc_004_events_ticket_types.sql`. It
adds no table and no column — only:

- `check_event_ticket_capacity(uuid)`, `enforce_ticket_type_capacity()` +
  `ticket_types_capacity_check` trigger, `enforce_event_capacity_change()`
  - `events_capacity_check` trigger — the capacity-vs-inventory invariant
    (see "Event capacity" above).
- `enforce_event_publish_invariants()` + `events_publish_invariants_check`
  trigger — the publication invariant backstop (see "Event publication"
  above).

Every new function is `SECURITY INVOKER` (the default — stated explicitly
in the migration, matching RFC-003's own precedent): each runs as the
same role performing the write, which already has `SELECT` access to both
`events` and `ticket_types` via RFC-002's existing RLS policies, so no
elevated privilege is needed and none is used. Neither the RFC-002 nor the
RFC-003 migration was modified.

## Tests

`supabase/tests/database/rfc_004_events_ticket_types.test.sql` — 20 new
pgTAP assertions. Deliberately does not re-verify everything RFC-002
already covers for `events`/`ticket_types` (cross-org read isolation,
cross-org INSERT rejection, the tenant-consistency FK, basic price/quantity
CHECK constraints — see `rfc_002_security.test.sql`). It focuses on:

- the full OWNER/ADMIN/PRODUCER/DOOR_STAFF/VIEWER role matrix for
  **UPDATE** specifically (RFC-002 only exercised INSERT for this matrix);
  note that an unauthorized `UPDATE` under RLS doesn't throw — its `USING`
  clause silently excludes the row (0 rows affected) — so these are proven
  by showing the row is unaffected, not by expecting an exception, unlike
  the INSERT case;
- the two new triggers: ticket inventory vs. capacity (both directions —
  growing inventory past capacity, and lowering capacity below existing
  inventory), and publication invariants (no venue, no ticket types, only
  a `HIDDEN` ticket type, and the positive case).

Combined with RFC-002 (22) and RFC-003 (14): **56 total pgTAP assertions**
in the local verification I could run from this sandbox (see
"Validation" in the final response for what that was and was not — real
`supabase test db` must still be run against the actual local Supabase
stack, which this sandbox cannot reach).

## Generated database types

This migration adds no table or column, and the code in this RFC doesn't
call either new database function directly (they're triggers, not RPCs),
so `src/types/database.ts` did not need to change for anything in this RFC
to typecheck. Regenerating it after any new migration remains good
practice regardless — see the final response's "Local Commands I Must
Run" for the exact command. `src/types/database.ts` was not hand-edited.

## Deferred

- Ticket holds, inventory reservation, checkout locking, overselling
  protection, orders, payments, webhooks — explicitly RFC-006+.
- The public event page and public event discovery — RFC-005.
- Deriving `ON_SALE`/`SOLD_OUT`/`UPCOMING`/`PAST` from
  status/dates/inventory for display — not needed until there's a public
  page or a richer dashboard view to show it on.
- Image upload for `events.cover_image_url` — the column already exists
  (RFC-002) but no RFC-004 screen exposes it; not "strictly required by
  the existing schema" for this RFC's scope.
- An automated application-level test runner (Playwright/Vitest) — same
  gap RFC-003 already deferred; still not added speculatively here.
- No enforcement that a published event automatically reverts to DRAFT if
  its last sellable ticket type is later removed/deactivated — the
  publish-time trigger checks at the moment of publishing, not
  continuously; revisit if this becomes a real operational problem.
