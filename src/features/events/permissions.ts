import "server-only";

import {
  requireOrganizationRole,
  type OrganizationContext,
} from "@/lib/auth/require-organization";

/**
 * RFC-004 "Permissions" - least-privilege model for events and ticket
 * types: OWNER/ADMIN/PRODUCER manage (create/edit/publish); DOOR_STAFF has
 * no event-configuration mutations; VIEWER is read-only. Read access for
 * every role, including DOOR_STAFF and VIEWER, is already granted by
 * RFC-002's `events_select_member` / `ticket_types_select_member` RLS
 * policies (any organization member, any role) and by
 * `requireOrganizationMembership` - no separate read-permission check
 * exists or is needed here.
 */
export const EVENT_MANAGER_ROLES = ["OWNER", "ADMIN", "PRODUCER"] as const;

export type EventManagerRole = (typeof EVENT_MANAGER_ROLES)[number];

export function isEventManagerRole(role: string): role is EventManagerRole {
  return (EVENT_MANAGER_ROLES as readonly string[]).includes(role);
}

/**
 * Requires the caller to hold one of EVENT_MANAGER_ROLES in the
 * organization named by `organizationSlug`. Every event/ticket-type
 * Server Action calls this before doing anything else, and every
 * event-management page calls it to keep organizer-only screens
 * unreachable by DOOR_STAFF/VIEWER, not just their mutation buttons
 * hidden - "hiding a button is not authorization" (RFC-004 "Permissions").
 * Delegates to `requireOrganizationRole` (RFC-003), which redirects rather
 * than throwing on failure - see that function's own documentation for
 * the routing rationale.
 */
export async function requireEventManager(
  organizationSlug: string,
): Promise<OrganizationContext> {
  return requireOrganizationRole(organizationSlug, EVENT_MANAGER_ROLES);
}
