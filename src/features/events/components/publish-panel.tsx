"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";

import { publishEventAction } from "@/features/events/actions";
import type { EventRow } from "@/features/events/queries";

type PublishPanelProps = {
  organizationSlug: string;
  event: EventRow;
  /** Computed server-side via getPublishIssues() against the event's current ticket types - see the management page. Empty means publishable. */
  issues: string[];
  canManage: boolean;
};

const STATUS_LABEL: Record<string, string> = {
  DRAFT: "Draft",
  PUBLISHED: "Published",
  FINISHED: "Finished",
  CANCELLED: "Cancelled",
  ARCHIVED: "Archived",
};

export function PublishPanel({
  organizationSlug,
  event,
  issues,
  canManage,
}: PublishPanelProps) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const handlePublish = () => {
    setError(null);

    startTransition(async () => {
      const result = await publishEventAction(organizationSlug, event.id);

      if (result.status === "error") {
        setError(result.error);
        return;
      }

      router.refresh();
    });
  };

  return (
    <div className="flex flex-col gap-3 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800">
      <div className="flex items-center justify-between gap-3">
        <span className="text-sm font-medium text-zinc-900 dark:text-zinc-100">
          Status
        </span>
        <span className="inline-flex w-fit items-center rounded-full border border-zinc-300 px-2.5 py-0.5 text-xs font-medium text-zinc-700 dark:border-zinc-700 dark:text-zinc-300">
          {STATUS_LABEL[event.status] ?? event.status}
        </span>
      </div>

      {event.status === "DRAFT" && canManage ? (
        <>
          {issues.length > 0 ? (
            <ul className="flex list-disc flex-col gap-1 pl-5 text-sm text-zinc-600 dark:text-zinc-400">
              {issues.map((issue) => (
                <li key={issue}>{issue}</li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">
              This event is ready to publish.
            </p>
          )}

          {error ? (
            <p role="alert" className="text-sm text-red-600 dark:text-red-400">
              {error}
            </p>
          ) : null}

          <button
            type="button"
            onClick={handlePublish}
            disabled={isPending || issues.length > 0}
            className="w-fit rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-zinc-50 disabled:opacity-60 dark:bg-zinc-50 dark:text-zinc-950"
          >
            {isPending ? "Publishing…" : "Publish event"}
          </button>
        </>
      ) : null}
    </div>
  );
}
