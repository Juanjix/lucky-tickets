import "server-only";

import type { AuthError } from "@supabase/supabase-js";

/**
 * Maps a Supabase Auth error to a message safe to show a user, never the
 * raw `error.message` (which can describe internal provider state). Codes
 * are `@supabase/auth-js`'s documented `ErrorCode` values.
 *
 * Deliberately vague about *why* sign-in failed (wrong email vs wrong
 * password get the same message) — distinguishing them lets an attacker
 * enumerate registered emails.
 */
export function toPublicAuthError(error: AuthError): string {
  switch (error.code) {
    case "invalid_credentials":
      return "Incorrect email or password.";
    case "user_already_exists":
    case "email_exists":
      return "An account with that email already exists. Try signing in instead.";
    case "weak_password":
      return "Choose a stronger password (at least 8 characters).";
    case "email_address_invalid":
      return "Enter a valid email address.";
    case "email_not_confirmed":
      return "Confirm your email before signing in — check your inbox for the confirmation link.";
    case "signup_disabled":
      return "Sign-up is currently disabled for this project.";
    case "over_email_send_rate_limit":
    case "over_request_rate_limit":
      return "Too many attempts. Please wait a few minutes and try again.";
    default:
      return "Something went wrong. Please try again.";
  }
}
