/**
 * Narrow DTOs for the tickets feature (RFC-008).
 */

/** One ticket as rendered on the buyer-facing tickets page - already includes its rendered QR image, never the raw token itself. */
export type BuyerTicket = {
  ticketId: string;
  ticketNumber: string;
  status: string;
  ticketTypeName: string;
  qrImageDataUrl: string;
  issuedAt: string | null;
  checkedInAt: string | null;
};

/** The full buyer-facing tickets-page payload for one order. */
export type BuyerOrderTickets = {
  orderId: string;
  orderStatus: string;
  eventName: string;
  eventStartsAt: string;
  eventVenueName: string | null;
  organizationName: string;
  tickets: BuyerTicket[];
};
