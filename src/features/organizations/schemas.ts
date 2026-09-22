import { z } from "zod";

/**
 * Client-and-server-shared validation for organization creation. The
 * database has the final say (`organizations_name_not_blank`,
 * `organizations_slug_format` in the RFC-002 migration) — this schema
 * exists to give the user fast, specific feedback, not to replace those
 * constraints.
 */
export const createOrganizationSchema = z.object({
  name: z
    .string()
    .trim()
    .min(2, "Organization name must be at least 2 characters.")
    .max(120, "Organization name must be 120 characters or fewer."),
});

export type CreateOrganizationInput = z.infer<typeof createOrganizationSchema>;
