import "server-only";

import QRCode from "qrcode";

/**
 * QR content encoding (RFC-008).
 *
 * A versioned, compact, non-URL string - `lt:v1:<rawToken>` - rather than
 * a scannable `https://...` link. Two deliberate choices:
 *
 *   - Versioned (`v1`) from day one so a future RFC-009 change (a
 *     different token format, a different hashing scheme) can be
 *     distinguished from existing issued tickets without a backfill -
 *     RFC-009's scanner reads the prefix before deciding how to validate
 *     the rest.
 *   - NOT a URL: a generic camera app's "open link" affordance is exactly
 *     the wrong UX for a venue-entry credential (it should be scanned by
 *     RFC-009's own dedicated scanner, never casually opened in a
 *     browser), and keeping it a short opaque string also keeps the QR
 *     payload small (more reliable scans, smaller/denser code than a full
 *     URL would need) and avoids the raw secret ever appearing as a
 *     clickable link in a phone's photo library, notification, or share
 *     sheet the way a URL-shaped QR sometimes does.
 *
 * The content is intentionally NEVER personal data (no email, name, event
 * name, ticket type) - only the raw secret itself. RFC-009's scanner
 * hashes whatever follows `lt:v1:` (sha256, hex) and looks it up against
 * `tickets.qr_token_hash` - a single indexed equality lookup, no
 * decryption needed on that hot path.
 */
const QR_CONTENT_VERSION = "v1";

export function buildQrContent(rawToken: string): string {
  return `lt:${QR_CONTENT_VERSION}:${rawToken}`;
}

/**
 * Renders a ticket's QR content as a PNG data URL, ready to drop directly
 * into an `<img src>` - no client-side JS, no canvas, no separate image
 * route needed. Rendered fresh on every request from the decrypted raw
 * token (see `src/features/tickets/queries.ts`); nothing about the
 * rendered image is ever cached or persisted.
 */
export async function renderTicketQrDataUrl(rawToken: string): Promise<string> {
  return QRCode.toDataURL(buildQrContent(rawToken), {
    errorCorrectionLevel: "M",
    margin: 1,
    width: 320,
  });
}
