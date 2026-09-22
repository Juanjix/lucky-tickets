import "server-only";

import { AppError } from "@/lib/errors/app-error";
import type { SupabaseServerClient } from "@/lib/supabase/server";

export type MyOrganization = {
  id: string;
  slug: string;
  name: string;
};

/**
 * The organizations the current session's user belongs to, alphabetically
 * by name — used to render the organization switcher. Relies entirely on
 * `organization_members_select_member` / `organizations_select_member`
 * RLS: this issues no `user_id` filter of its own, because scoping "my
 * organizations" to the caller is exactly what those policies already do.
 */
export async function listMyOrganizations(
  supabase: SupabaseServerClient,
): Promise<MyOrganization[]> {
  const { data, error } = await supabase
    .from("organization_members")
    .select("organizations(id, slug, name)")
    .order("name", { referencedTable: "organizations", ascending: true });

  if (error) {
    throw new AppError("internal", "Failed to load organizations.", {
      cause: error,
    });
  }

  return (data ?? [])
    .map((row) => row.organizations)
    .filter(
      (organization): organization is MyOrganization => organization !== null,
    );
}
