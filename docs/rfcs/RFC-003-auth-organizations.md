# RFC-003 — Authentication & Organizations

**Status:** Implemented. Builds on RFC-001 (Next.js/Supabase foundation) and
RFC-002 (database schema, tenant isolation, RLS) without modifying either's
decisions except where noted below.

## Goals

Establish the authentication and multi-tenant application layer: a user can
sign up, sign in, sign out, and maintain a session; a signed-in user with no
organization is guided to create one and becomes its `OWNER`; a user can
belong to multiple organizations and switch between them; dashboard routes
are scoped to one organization by slug and inaccessible to non-members; and
authorization is enforced server-side, backed by PostgreSQL RLS as the final
boundary — never by trusting anything the client claims about its own
permissions.

Explicitly not in scope (deferred to later RFCs): event management, ticket
types, checkout, payments, webhooks, ticket issuance, QR/check-in, guest
lists, billing, OAuth providers, invitations, and team-member-management UI.
See "Deferred" below.

## Architecture

```text
src/lib/auth/
  require-user.ts          requireUser(), getOptionalUser()
  require-organization.ts  requireOrganizationMembership(), requireOrganizationRole()
  auth-errors.ts           Supabase AuthError -> safe user-facing message

src/lib/slug.ts             slugify(): free text -> URL-safe candidate slug

src/features/auth/
  schemas.ts                 Zod: signUpSchema, signInSchema
  actions.ts                 "use server": signUpAction, signInAction, signOutAction
  components/
    login-form.tsx           "use client", React Hook Form + Zod
    signup-form.tsx
    sign-out-button.tsx       plain <form action={signOutAction}>, no client JS

src/features/organizations/
  schemas.ts                  Zod: createOrganizationSchema
  actions.ts                  "use server": createOrganizationAction (calls the create_organization RPC)
  server/
    resolve-landing-path.ts   first organization, or /onboarding
    list-my-organizations.ts  for the switcher
  components/
    create-organization-form.tsx
    organization-switcher.tsx

src/app/
  login/page.tsx
  signup/page.tsx
  onboarding/page.tsx
  auth/confirm/route.ts       completes Supabase's email-confirmation link
  dashboard/page.tsx                              slug-less index, always redirects
  dashboard/[organizationSlug]/layout.tsx         membership check, header, switcher
  dashboard/[organizationSlug]/page.tsx           minimal org home
```

No new abstraction folder (`lib/validation/`, a shared `components/ui/`
input primitive, etc.) was introduced beyond what this RFC's forms
concretely needed — see `docs/architecture.md`'s existing note that these
appear when a real feature needs them, not speculatively.

## Authentication flow

Email/password only, via Supabase Auth, through the existing `@supabase/ssr`
client factories from RFC-001 (`src/lib/supabase/client.ts` for Client
Components, `server.ts` for Server Components/Actions/Route Handlers) — no
second client architecture, no deprecated auth helpers.

- **Sign up** (`signUpAction`): validates with `signUpSchema`, calls
  `supabase.auth.signUp()`. Whether this returns an active session
  immediately or requires email confirmation first depends entirely on the
  Supabase project's own "Confirm email" setting, which this codebase does
  not control — both outcomes are handled. If a session comes back, the user
  proceeds straight to `/onboarding`. If not, the UI shows "check your
  email" and `/auth/confirm` (a Route Handler) completes sign-up when the
  confirmation link is clicked, via `supabase.auth.verifyOtp()`. This is
  Supabase Auth's standard confirmation email, not a magic link or
  passwordless sign-in — RFC-003 excludes those.
- **Sign in** (`signInAction`): validates with `signInSchema`, calls
  `supabase.auth.signInWithPassword()`.
- **Sign out** (`signOutAction`): calls `supabase.auth.signOut()` and
  redirects to `/login`. Bound directly to a plain `<form action={...}>` —
  the one case where calling `redirect()` inside a Server Action is
  unambiguously safe without a client-side fallback (see ADR-008 in
  `docs/architecture.md`).
- **Session verification**: every server-side identity check goes through
  `getOptionalUser()`/`requireUser()` (`src/lib/auth/require-user.ts`), which
  calls `supabase.auth.getClaims()` — the same method `src/lib/supabase/proxy.ts`
  already used for session refresh — rather than trusting cookie content
  directly. `getClaims()` verifies the JWT before returning its contents;
  reading a raw session/cookie value would not be a verified identity claim.
- **Errors**: Supabase `AuthError.code` values are mapped to safe, generic
  messages by `toPublicAuthError()` (`src/lib/auth/auth-errors.ts`) — e.g.
  wrong email and wrong password both produce "Incorrect email or
  password," deliberately, so sign-in failures can't be used to enumerate
  registered emails.

## Profile provisioning

**No new migration was needed.** RFC-002 already created
`public.handle_new_user()` (a `SECURITY DEFINER` trigger function) and its
`on_auth_user_created` trigger on `auth.users`, which idempotently inserts a
`public.profiles` row for every new `auth.users` row
(`on conflict (id) do nothing`). Verified by inspection of the RFC-002
migration before writing any RFC-003 code, per that RFC's explicit
instruction not to duplicate work RFC-002 already did. The invariant "every
`auth.users` row has exactly one `profiles` row" holds regardless of how the
user was created (through this app's sign-up form, the Supabase dashboard,
or any other path that inserts into `auth.users`), because it's a database
trigger, not application code that only runs on one code path.

## Organization creation

A new migration, `supabase/migrations/20260921000000_rfc_003_organization_provisioning.sql`,
adds `public.create_organization(p_name, p_slug, p_timezone)`.

**Why a database function was necessary.** Creating an organization and its
first `OWNER` membership as two separate PostgREST calls from application
code cannot be made atomic from the client — each call is its own
transaction. If the second call failed, the result would be an organization
with zero members, which is permanently unreachable: every RLS policy in
the system gates on `organization_members`, and RFC-002's own bootstrap
policy (`organization_members_insert_bootstrap_owner`) only permits adding
an `OWNER` to an organization with _zero existing members_ — so an
already-populated-with-zero-but-orphaned org can never be recovered through
the normal API. A single `plpgsql` function call is one statement in the
calling transaction: if the second insert fails, the whole function's
effects (including the first insert) roll back. This is the "simplest
production-safe solution" the RFC asked for — no new database primitive
(advisory locks, two-phase commit) was needed, just moving both inserts
into one atomic unit.

**`SECURITY INVOKER`, not `SECURITY DEFINER`.** The function runs as the
calling user, so RFC-002's existing RLS policies
(`organizations_insert_authenticated`, `organization_members_insert_bootstrap_owner`)
are what actually authorize its two inserts — this function adds no new
authorization logic of its own, it only makes an already-legal sequence of
operations atomic. This is also what "never bypass RLS for normal
authenticated application behavior" (RFC-003 "RLS") requires: the
service-role key is not used anywhere in this RPC or in any user-facing
flow in this RFC.

**A genuine RLS-ordering finding, discovered while writing this migration's
own pgTAP coverage.** The first version of this function used
`insert into organizations (...) returning * into v_org`. That failed with
"new row violates row-level security policy for table organizations" —
not because the insert was unauthorized (`organizations_insert_authenticated`
permits it unconditionally), but because PostgreSQL evaluates a statement's
`RETURNING` projection against the table's **SELECT** policies too, and at
the instant the organization is inserted its creator is not a member of it
yet (that only becomes true after the second insert). The fix, in the
shipped migration: generate the row's `id` explicitly, insert without
`RETURNING`, insert the `OWNER` membership (which makes the creator a
member), and only then `SELECT` the row back — by which point
`organizations_select_member` passes normally. No RLS policy was weakened
or bypassed to make this work; this is a consequence of how RFC-002's RLS
was designed, worked around correctly rather than around.

**Slug collisions** are resolved inside the function: on a `unique_violation`
against `organizations.slug`, it appends a numeric suffix (`-2`, `-3`, ...,
up to 5 attempts) and retries in a `plpgsql` exception block (an implicit
subtransaction per attempt), rather than asking the client to guess an
available slug up front or failing the whole operation. Verified: "Los
Pibes Producciones" from two different users produces `los-pibes-producciones`
and `los-pibes-producciones-2`.

**A second real finding, also from writing this migration's tests**:
PostgreSQL grants `EXECUTE` on every newly created function to `PUBLIC` by
default, and this is **not** reliably overridden by
`ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`
issued beforehand (verified empirically — the override did not change the
ACL of a function created afterward in the same session, a genuine Postgres
behavior, not a test-environment artifact). Every role, including `anon`,
is implicitly a member of `PUBLIC`. Without an explicit
`revoke execute on function public.create_organization(...) from public;`
right in the migration, `anon` would have been able to call
`create_organization` despite never being named in a `grant`. The migration
includes this explicit revoke; a pgTAP test (`throws_ok` expecting `42501`)
locks it in.

### Security incident: `REVOKE ... FROM PUBLIC` was not enough on real Supabase

**What happened.** The two findings above were both verified against this
project's local Postgres substitute (a plain `apt`-installed PostgreSQL 16
with a hand-written shim reproducing `auth.uid()` and the `anon`/
`authenticated` roles — this sandbox has no Docker registry access, so the
real `supabase start` stack could not be run here). That substitute's pgTAP
suite passed 33/33. When the migration was then run for real, via
`npx supabase db reset` followed by `npx supabase test db` on a real local
Supabase stack, RFC-003's suite failed: test 1, "anon cannot execute
create_organization (no EXECUTE grant)", caught SQLSTATE `28000`
(`create_organization requires an authenticated user` — the function's own
internal check) instead of the expected `42501` (`permission denied for
function` — the privilege layer refusing entry). `anon` was reaching the
inside of the function body at all, on real Supabase, despite the `revoke
... from public` above.

**Root cause.** A real Supabase project's own bootstrap SQL (`roles.sql`,
applied before any project migration runs — visible in the `supabase db
reset` log as "Seeding globals from roles.sql...") pre-establishes something
equivalent to:

```sql
alter default privileges for role postgres in schema public
  grant execute on functions to anon, authenticated, service_role;
```

Project migrations run as the `postgres` role, so every function a
migration creates — including `create_organization` — receives a **direct,
separately-named** `EXECUTE` grant to `anon` at creation time, not one it
holds through its `PUBLIC` membership. `REVOKE EXECUTE ... FROM PUBLIC`
removes only the `PUBLIC` pseudo-role's own ACL entry; it does not touch a
different, directly-named ACL entry for `anon`. Confirmed directly by
inspecting `pg_proc.proacl` for `create_organization` and by
`has_function_privilege('anon', 'public.create_organization(text,text,text)',
'EXECUTE')` returning `true` before the fix below — not inferred from the
test failure alone. This is also exactly why the local substitute missed
it: a plain `apt` install has no Supabase-specific bootstrap, so it never
had this default privilege in the first place, and `revoke ... from public`
alone looked sufficient there.

**Fix.** One additional, signature-exact revoke in the same migration:

```sql
revoke execute on function public.create_organization(text, text, text) from anon;
```

added alongside (not instead of) the existing `revoke ... from public` and
`grant ... to authenticated`. `SECURITY INVOKER` was left unchanged — this
is a grant-table fix, not an authorization-model change — and RLS,
`auth.uid()`, and the service-role boundary are all untouched. Because this
migration had not been deployed to Supabase Cloud or production at the
time this was found, the existing migration file was corrected in place
rather than adding a second migration; RFC-002's migration was not touched.

**Test improvements.** The pgTAP suite (plan raised from 11 to 14) now
asserts the privilege grant directly via pgTAP's `function_privs_are()`
(which reads `pg_proc.proacl`, the same catalog inspected while diagnosing
this) rather than only inferring it from a call's behavior: `anon` has no
privileges at all on `create_organization`, `PUBLIC` has none either (so
`anon` cannot inherit any through it), and `authenticated` has exactly
`EXECUTE`. The pre-existing `throws_ok` behavioral test for `anon` (still
`42501`) and for an `authenticated` caller with no JWT `sub` claim (still
`28000`) were both kept, with their comments made explicit that these are
three independent layers being exercised on purpose — database privilege,
function-internal validation, and RLS — and that conflating any two of
them (e.g. accepting `28000` where `42501` is expected) would hide exactly
this class of regression rather than catch it. The local shim used in this
project was also corrected to reproduce Supabase's `roles.sql` default
privilege, so this bug class is now caught locally in this sandbox going
forward instead of only on a real Supabase run.

**Fields**: `name`, `slug`, `timezone` — the fields RFC-002 already defined
on `organizations`; no duplicate fields were introduced.
`America/Argentina/Buenos_Aires` is RFC-002's existing column default and is
what the function falls back to if `p_timezone` is blank.

## Tenant resolution (dashboard routing)

`requireOrganizationMembership(organizationSlug)`
(`src/lib/auth/require-organization.ts`) is the single place a slug becomes
a trusted `{ user, organization, membership }` context. It:

1. Requires a signed-in user (`requireUser`, redirecting to `/login?next=...`
   if absent — see "Routing" below for what `next` does).
2. Looks up `organizations` by slug. RLS (`organizations_select_member`)
   already means this can only return a row the caller is a member of.
3. Independently looks up the caller's own `organization_members` row for
   that organization. This is deliberate defense in depth, not redundant
   paranoia: RFC-003 requires "authorization enforced server-side **and**
   by PostgreSQL RLS" as two layers, not one. If step 2's RLS policy were
   ever weakened by a future change, step 3 would still refuse to proceed
   without a real membership row.
4. Returns the resolved context, or renders `notFound()` if either check
   fails.

`requireOrganizationRole(organizationSlug, allowedRoles)` builds on this,
additionally checking `membership.role`. RFC-004 (events) and later RFCs are
expected to call this rather than re-implementing role checks, e.g.
`requireOrganizationRole(slug, ["OWNER", "ADMIN", "PRODUCER"])`.

Both are wrapped in React's `cache()`, so the dashboard layout and the page
it renders can each call `requireOrganizationMembership` for the same
request without a duplicate database round trip — the standard Next.js App
Router per-request dedupe mechanism, not a cross-request cache.

## Organization switcher

Implemented as routing only, per the RFC's explicit instruction: the
`<select>` in `OrganizationSwitcher` calls `router.push('/dashboard/' + slug)`
on change and holds no state of its own. The URL remains the single source
of truth for which organization is active — there is no global
"current organization" store to keep in sync with it.

## Routing / security decisions

**404, not 403, for "no such organization" or "not a member."**
`requireOrganizationMembership` renders an ordinary 404
(`next/navigation`'s `notFound()`) whether the slug doesn't exist at all or
it exists but the caller isn't a member — the same response either way. A
403 would itself leak that the slug belongs to a real organization; RFC-002's
RLS was specifically designed so a member of Organization A cannot observe
whether Organization B exists (see `docs/database.md` "Tenant boundary").
Collapsing both cases into the same 404 preserves that property at the
application layer, not only at the database layer. See also
`docs/database.md`'s own answer to "can Organization A ever observe
Organization B" — this routing decision is the application-layer expression
of the same policy.

**403-shaped experience for "member, but wrong role."**
`requireOrganizationRole` redirects to `/dashboard/{slug}?error=forbidden`
instead of a bare notFound/403 page. This is different from the case above
because the caller already knows the organization exists (they're a member
of it) — hiding that would protect nothing. The dashboard org page reads
`?error=forbidden` and renders an inline message.

**Unauthenticated → `/login?next=<path>`, not 404 or 403.**
`requireUser` redirects with a `next` query param preserving the originally
requested path. `/login`'s `LoginForm` uses it (after validating it's a
same-origin path starting with a single `/`, guarding against an open
redirect via a protocol-relative `//host` value) to send the user back to
where they were headed after a successful sign-in, instead of always
landing on their default organization.

**No proxy-level authorization.** `src/proxy.ts` /
`src/lib/supabase/proxy.ts` (from RFC-001) still perform session-refresh
only. RFC-003 deliberately did not add redirect/authorization logic there,
consistent with that file's own existing comment ("per Next.js's own
guidance it must be re-verified inside each Server Action / Route Handler
regardless of Proxy having run") and to avoid a second, parallel place
authorization logic could drift from `requireUser`/`requireOrganizationMembership`.
Every protected route calls these directly.

**Redirect map** (all implemented, none produce a loop — verified by
tracing each path below and manually exercising sign-up → onboarding →
sign-out → sign-in → dashboard → switch organization):

| From                      | Condition                                                 | To                                                                     |
| ------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------- |
| `/dashboard/*`            | unauthenticated                                           | `/login?next=<path>`                                                   |
| `/login`, `/signup`       | already authenticated                                     | first organization, or `/onboarding`                                   |
| `/dashboard` (no slug)    | authenticated                                             | first organization, or `/onboarding`                                   |
| `/onboarding`             | authenticated, already has an organization                | first organization's dashboard                                         |
| sign-up / sign-in success | —                                                         | `next` (login only, if safe) else first organization, or `/onboarding` |
| `/dashboard/{slug}`       | member, insufficient role (via `requireOrganizationRole`) | `/dashboard/{slug}?error=forbidden`                                    |

## Security

- **Never trust client-supplied organization identifiers for privileged
  operations.** The only place a client supplies an organization identifier
  is the `organizationSlug` URL segment (read-only navigation) and the
  `name` field when creating one (from which the server computes the slug).
  No Server Action accepts an `organizationId` and acts on it without
  independently re-deriving membership — `createOrganizationAction` doesn't
  take one at all (the RPC always uses `auth.uid()`), and
  `requireOrganizationMembership`/`requireOrganizationRole` are what every
  future organization-scoped action is expected to call first.
- **Two enforcement layers, not one.** RLS (RFC-002) is the final boundary;
  application code (`requireUser`, `requireOrganizationMembership`,
  `requireOrganizationRole`) is an additional, independent layer, per the
  RFC's explicit requirement. Neither assumes the other is sufficient on
  its own — see the "defense in depth" note under "Tenant resolution."
- **No service-role key anywhere in this RFC.** Every user-facing read and
  write — sign-up, sign-in, organization creation, membership/role lookups —
  executes under the caller's own JWT and RFC-002's existing RLS policies.
  `create_organization` is `SECURITY INVOKER` for the same reason.
- **`create_organization` is not callable by `anon`.** Both the missing
  `grant` and (necessarily) an explicit `revoke ... from public` — see
  "Organization creation" above for why the explicit revoke was required.
- **Typed database access.** `src/lib/supabase/client.ts` and `server.ts`
  (RFC-001) are parameterized with the generated `Database` type
  (`createBrowserClient<Database>`, `createServerClient<Database>`), so
  every `.from()`/`.rpc()` call in this RFC is checked against the real
  RFC-002/RFC-003 schema — not a change to the client architecture itself,
  just completing it now that generated types exist. `create_organization`
  is included in the real generated types (`src/types/database.ts`, via
  `npx supabase gen types typescript --local`), so
  `createOrganizationAction` (`src/features/organizations/actions.ts`) calls
  `supabase.rpc("create_organization", ...)` directly with no cast — the
  temporary, explicitly-documented workaround this RFC used while types
  predated the migration has been removed.

## Migrations introduced

`supabase/migrations/20260921000000_rfc_003_organization_provisioning.sql` —
adds `public.create_organization(text, text, text)` only. Does not modify
the RFC-002 migration file. No schema defect was found in RFC-002 that
would have justified changing it.

## Tests

`supabase/tests/database/rfc_003_organizations.test.sql` — 14 pgTAP
assertions, focused on the new database behavior only (per RFC-003's
instruction not to duplicate RFC-002's existing 22): three privilege-grant
assertions (`function_privs_are()` against `anon`, `PUBLIC`, and
`authenticated` — added after the real-Supabase privilege incident below;
they read `pg_proc.proacl` directly rather than inferring the grant from a
call's behavior); `anon` cannot execute `create_organization` (behavioral,
`42501`); an authenticated caller with no resolvable `auth.uid()` is
rejected explicitly (`28000`); a successful call creates both rows
atomically and the creator is immediately `OWNER`; tenant isolation holds
for organizations created through the RPC (a bystander user cannot see one
created for someone else); slug collisions resolve to a numeric suffix
rather than failing; and a single user can own more than one organization
(the `organization_members` many-to-many model, not "one organization per
user").

Combined with RFC-002's suite: **36 total pgTAP assertions**, all passing on
the real local Supabase stack — see "Validation" below.

Application-level auth/tenancy behavior (the DoD's "unauthenticated
dashboard access is blocked", "User A cannot access Organization B", the
redirect map above) was verified by manual exercise of the running
application (`npm run build && npm run start`, and by tracing each
Server Component/Action's logic against the pgTAP-verified database) rather
than an automated Next.js integration-test suite — no test runner
(Playwright, Vitest, etc.) exists in this project yet, and adding one
purely for this RFC was judged out of scope; see "Deferred."

## Validation

This RFC was validated against the **real local Supabase CLI stack**
(Docker), run by the project owner on their own machine — not a substitute
environment — with these results:

```text
Supabase DB reset:  PASS  (both migrations applied cleanly)
RFC-002 pgTAP:      PASS  — 22/22
RFC-003 pgTAP:      PASS  — 14/14
Total pgTAP:        PASS  — 36/36
Generated types:    PASS  — npx supabase gen types typescript --local
```

```bash
npx supabase db reset
npx supabase test db
# Files=2, Tests=36, Result: PASS

npx supabase gen types typescript --local > src/types/database.ts
```

**Final `create_organization` security model, confirmed on real Supabase:**

```text
PUBLIC          EXECUTE = false
anon            EXECUTE = false
authenticated   EXECUTE = true
SECURITY        INVOKER
RLS             enforced (organizations_insert_authenticated,
                          organization_members_insert_bootstrap_owner,
                          organizations_select_member — all RFC-002, unchanged)
```

**History — why this took two passes.** The code and migration in this RFC
were originally written and pgTAP-verified in a sandboxed development
environment with no Docker registry access, against a hand-written
substitute (a plain PostgreSQL 16 install with `auth.uid()`/`anon`/
`authenticated` reproduced by hand — see the git history of
`docs/rfcs/RFC-003-auth-organizations.md` and the migration's own comments
for specifics). That substitute passed 33/33 pgTAP assertions but was not a
real Supabase project, and it missed one thing a real Supabase project does
differently: see "Security incident: `REVOKE ... FROM PUBLIC` was not
enough on real Supabase" above. Real `npx supabase test db`, run by the
project owner, is what actually caught it. The fix (an additional
`revoke ... from anon`, plus 3 new privilege-introspection assertions) is
what brought the suite to the 36/36 confirmed above — this section, not the
substitute environment's earlier 33/33, is RFC-003's real validation record.
Once real types were generated, the temporary RPC type cast in
`src/features/organizations/actions.ts` (see "Manual steps required",
historical) was removed; `createOrganizationAction` now calls
`supabase.rpc("create_organization", ...)` directly, checked against the
real generated `Database["public"]["Functions"]["create_organization"]`
type with no cast in between.

## Deferred

- **No automated application-level test runner.** Route protection and
  redirect behavior were verified manually and by code review against the
  database-verified RLS/authorization model, not by an automated browser or
  component test suite. Introducing one (Playwright for the redirect map,
  Vitest for `slugify`/schema unit tests) is reasonable future work but was
  not added speculatively here.
- **Invitations / team member management UI** — explicitly out of scope
  per the RFC; `organization_members_insert_by_admin` (RFC-002) already
  supports an OWNER/ADMIN adding a member at the database level, but no UI
  or Server Action calls it yet.
- **No enforcement that an organization always retains ≥1 OWNER** — an
  RFC-002 deferred item, unchanged by RFC-003 (organization creation always
  produces exactly one OWNER; removing the last owner remains unguarded, as
  documented in `docs/database.md`).
- **OAuth, magic links, MFA, passwordless** — explicitly excluded by the RFC.
- **`docs/rfcs/RFC-001...` / `RFC-002...` retroactive files** were not
  created — those RFCs predate this doc convention and are already recorded
  in `docs/architecture.md` and `docs/database.md`. Only RFC-003 onward uses
  `docs/rfcs/`.

## Manual steps required (Supabase Cloud)

`npx supabase db reset` / `npx supabase test db` / `npx supabase gen types`
have all been run for real against the local Supabase CLI stack — see
"Validation" above; those are no longer open items. The following remain
genuinely manual, and are unrelated to the local database work:

1. **Supabase Cloud project** (if not already linked from RFC-001/002): if
   this repository is not yet linked to a Cloud project, creating one,
   obtaining its project reference, `supabase login`, `supabase link`, and
   `supabase db push` are all manual steps that need real credentials and
   were not invented as placeholder values here. `.env.local` (git-ignored,
   never committed) needs real `NEXT_PUBLIC_SUPABASE_URL` /
   `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` values from that project for the
   app to run against it.
2. **Confirm the "Confirm email" auth setting** matches your expectations
   for sign-up — RFC-003 handles both settings correctly (see "Authentication
   flow"), but which one is active is a Cloud/local project setting, not
   application code.
