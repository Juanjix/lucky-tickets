import "server-only";

import type { Json } from "@/types/database";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getPaymentServerEnv } from "@/lib/env/server";
import { verifyWebhookSignature } from "@/lib/mercado-pago/signature";
import { mapProviderStatusToPaymentStatus } from "@/lib/mercado-pago/mapper";
import { MercadoPagoPaymentGateway } from "@/services/payment-gateway/mercado-pago-payment-gateway";

/**
 * `POST /api/webhooks/mercado-pago` orchestration (RFC-007 sections
 * 19-23, 28-30, 43-44).
 *
 * HTTP status philosophy (section 43: "differentiate ... do not return
 * arbitrary 500 responses for already-processed duplicate events"):
 *   - 401: invalid/missing signature. No database write at all - an
 *     unauthenticated request must not be able to create ANY row, even a
 *     webhook_events one keyed by attacker-controlled ids (that could
 *     otherwise pre-empt/block a legitimate future delivery via the
 *     unique constraint - see this module's inline note below).
 *   - 200: every case where Mercado Pago retrying would not help -
 *     already processed, unsupported event type, a permanent domain
 *     mismatch (amount/currency/state/order-not-found) recorded for human
 *     review via audit_logs/webhook_events.error_message. Returning
 *     non-2xx for these would just make Mercado Pago retry something that
 *     will NEVER succeed differently.
 *   - 502/500: a genuinely transient failure (Mercado Pago's own API
 *     unreachable, or an unexpected database error) - here retrying
 *     (Mercado Pago's own documented backoff schedule) is exactly the
 *     right behavior, so a non-2xx is returned on purpose.
 */

export type WebhookProcessResult = {
  httpStatus: number;
  reason: string;
};

function safePayloadSubset(body: unknown): Json {
  if (!body || typeof body !== "object") {
    return {};
  }
  // `body` is the result of JSON.parse, so every value reachable from it is
  // already JSON-shaped at runtime - this cast just tells TypeScript what
  // JSON.parse's `any` return actually guarantees.
  const record = body as Record<string, Json>;
  return {
    id: record.id ?? null,
    type: record.type ?? null,
    action: record.action ?? null,
    data: record.data ?? null,
    live_mode: record.live_mode ?? null,
  };
}

export async function processMercadoPagoWebhook(input: {
  signatureHeader: string | null;
  requestId: string | null;
  queryDataId: string | null;
  queryType: string | null;
  rawBody: string;
}): Promise<WebhookProcessResult> {
  let body: unknown = null;
  try {
    body = input.rawBody ? JSON.parse(input.rawBody) : null;
  } catch {
    body = null;
  }

  const bodyRecord =
    body && typeof body === "object" ? (body as Record<string, unknown>) : {};
  const bodyData =
    bodyRecord.data && typeof bodyRecord.data === "object"
      ? (bodyRecord.data as Record<string, unknown>)
      : {};

  const dataId =
    input.queryDataId ??
    (bodyData.id !== undefined && bodyData.id !== null
      ? String(bodyData.id)
      : null);

  const { MERCADO_PAGO_WEBHOOK_SECRET } = getPaymentServerEnv();

  const signatureValid = verifyWebhookSignature({
    signatureHeader: input.signatureHeader,
    requestId: input.requestId,
    dataId,
    secret: MERCADO_PAGO_WEBHOOK_SECRET,
  });

  if (!signatureValid) {
    // Deliberately no database write here - see this module's doc comment
    // on why recording anything keyed by an unauthenticated id is unsafe.
    console.warn(
      "[POST /api/webhooks/mercado-pago] rejected notification with invalid or missing signature",
    );
    return { httpStatus: 401, reason: "invalid_signature" };
  }

  const supabase = createServiceRoleClient();

  const notificationType =
    (typeof bodyRecord.type === "string" ? bodyRecord.type : null) ??
    input.queryType;

  if (notificationType !== "payment") {
    // RFC-007 section 44: safely IGNORE anything we don't act on (Point
    // device events, subscriptions, mp-connect, ...) rather than crash or
    // misinterpret it as a payment.
    const notificationId =
      bodyRecord.id !== undefined && bodyRecord.id !== null
        ? String(bodyRecord.id)
        : `unsupported:${dataId ?? input.requestId ?? Date.now()}`;

    const { data, error } = await supabase.rpc("record_webhook_event", {
      p_provider: "MERCADO_PAGO",
      p_provider_event_id: notificationId,
      p_event_type: notificationType ?? "unknown",
      p_payload: safePayloadSubset(body),
    });

    if (!error && data?.[0]) {
      await supabase.rpc("mark_webhook_event", {
        p_webhook_event_id: data[0].webhook_event_id,
        p_status: "IGNORED",
        p_error_message: `Unsupported notification type: ${notificationType ?? "unknown"}`,
      });
    }

    return { httpStatus: 200, reason: "unsupported_type_ignored" };
  }

  if (!dataId) {
    return { httpStatus: 400, reason: "missing_data_id" };
  }

  const notificationId =
    bodyRecord.id !== undefined && bodyRecord.id !== null
      ? String(bodyRecord.id)
      : `payment:${dataId}`;

  const { data: recordedEvent, error: recordError } = await supabase.rpc(
    "record_webhook_event",
    {
      p_provider: "MERCADO_PAGO",
      p_provider_event_id: notificationId,
      p_event_type:
        (typeof bodyRecord.action === "string" ? bodyRecord.action : null) ??
        "payment",
      p_payload: safePayloadSubset(body),
    },
  );

  if (recordError || !recordedEvent?.[0]) {
    console.error(
      "[POST /api/webhooks/mercado-pago] failed to record webhook receipt",
      { code: (recordError as { code?: string } | null)?.code },
    );
    return { httpStatus: 500, reason: "record_webhook_event_failed" };
  }

  const webhookEventRow = recordedEvent[0];

  if (
    webhookEventRow.already_existed &&
    webhookEventRow.status === "PROCESSED"
  ) {
    // Idempotent no-op (RFC-007 sections 28/30): this exact notification
    // delivery was already fully processed - no need to even re-fetch the
    // payment from Mercado Pago again.
    return { httpStatus: 200, reason: "already_processed" };
  }

  const gateway = new MercadoPagoPaymentGateway();

  let providerPayment;
  try {
    providerPayment = await gateway.getPayment(dataId);
  } catch (cause) {
    console.error(
      "[POST /api/webhooks/mercado-pago] failed to fetch payment from Mercado Pago",
      {
        providerPaymentId: dataId,
        message: cause instanceof Error ? cause.message : String(cause),
      },
    );
    await supabase.rpc("mark_webhook_event", {
      p_webhook_event_id: webhookEventRow.webhook_event_id,
      p_status: "FAILED",
      p_error_message:
        "Failed to fetch payment resource from Mercado Pago API.",
    });
    // Transient (network/provider outage) - let Mercado Pago's documented
    // retry schedule try again later (RFC-007 section 43).
    return { httpStatus: 502, reason: "provider_fetch_failed" };
  }

  if (!providerPayment.externalReference) {
    await supabase.rpc("mark_webhook_event", {
      p_webhook_event_id: webhookEventRow.webhook_event_id,
      p_status: "FAILED",
      p_error_message:
        "Payment has no external_reference to correlate with an order.",
    });
    // Permanent domain mismatch - retrying will never produce a
    // different external_reference, so acknowledge receipt (200) rather
    // than trigger Mercado Pago's retry schedule for nothing.
    return { httpStatus: 200, reason: "missing_external_reference" };
  }

  const { data: confirmData, error: confirmError } = await supabase.rpc(
    "confirm_order_payment",
    {
      p_order_id: providerPayment.externalReference,
      p_provider: "MERCADO_PAGO",
      p_provider_payment_id: providerPayment.providerPaymentId,
      p_status: mapProviderStatusToPaymentStatus(providerPayment.status),
      p_paid_amount_minor: providerPayment.transactionAmountMinor,
      p_currency: providerPayment.currency,
      p_payment_method: providerPayment.paymentMethod,
      p_provider_payload: providerPayment.safePayload,
      p_approved_at: providerPayment.approvedAt,
      p_webhook_event_id: webhookEventRow.webhook_event_id,
    },
  );

  if (confirmError) {
    const code = (confirmError as { code?: string }).code;

    await supabase.rpc("mark_webhook_event", {
      p_webhook_event_id: webhookEventRow.webhook_event_id,
      p_status: "FAILED",
      p_error_message:
        code === "LT010"
          ? "Order not found for this payment's external_reference."
          : "Unexpected error while confirming payment.",
    });

    if (code === "LT010") {
      // Permanent - this order id will never exist. Acknowledge so
      // Mercado Pago stops retrying.
      return { httpStatus: 200, reason: "order_not_found" };
    }

    console.error(
      "[POST /api/webhooks/mercado-pago] unexpected confirm_order_payment failure",
      { code },
    );
    return { httpStatus: 500, reason: "confirm_order_payment_failed" };
  }

  const outcome = confirmData?.[0]?.outcome ?? "UNKNOWN";
  // confirm_order_payment already marked webhook_events PROCESSED and
  // wrote its own audit_logs diagnostic for every outcome (including
  // rejections) - every outcome here is a "we made a final decision"
  // case, so every one of them acknowledges with 200 (RFC-007 section 43:
  // do not keep retrying a permanent domain mismatch).
  return { httpStatus: 200, reason: outcome.toLowerCase() };
}
