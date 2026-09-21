/**
 * Application-level configuration that isn't a secret and isn't tied to any
 * one feature — currently just the identity used in metadata and the root
 * page. Add to this file only when a value is genuinely shared across
 * unrelated parts of the app; feature-specific config belongs with the
 * feature, not here.
 */
export const siteConfig = {
  name: "Lucky Ticket",
  tagline: "Independent events, better organized.",
  description:
    "Ticketing and operations for independent event organizers, producers, bands, and venues.",
} as const;
