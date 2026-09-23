import { CreateEventForm } from "@/features/events/components/create-event-form";
import { requireEventManager } from "@/features/events/permissions";

/**
 * Gated by requireEventManager (not just requireOrganizationMembership):
 * DOOR_STAFF/VIEWER are redirected away from this screen entirely, not
 * just denied at submit time - "hiding a button is not authorization"
 * cuts both ways (RFC-004 "Permissions").
 */
export default async function NewEventPage(
  props: PageProps<"/dashboard/[organizationSlug]/events/new">,
) {
  const { organizationSlug } = await props.params;
  await requireEventManager(organizationSlug);

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
        Create event
      </h1>
      <CreateEventForm organizationSlug={organizationSlug} />
    </div>
  );
}
