import { signOutAction } from "@/features/auth/actions";

/**
 * Plain form bound directly to the `signOutAction` Server Action — no
 * client component, no JS required for it to work. This is the case
 * `redirect()` inside a Server Action is meant for (see the comment on
 * `signOutAction`).
 */
export function SignOutButton() {
  return (
    <form action={signOutAction}>
      <button
        type="submit"
        className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-900 dark:border-zinc-700 dark:text-zinc-100"
      >
        Sign out
      </button>
    </form>
  );
}
