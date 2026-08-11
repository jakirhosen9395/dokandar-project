// Kafka event → bilingual notification mapping (architecture §4.1, §10). PURE functions —
// no I/O, no config import, no side effects — so they are trivially testable and the
// consumer owns all the brokers. The consumer resolves the configured topic name to a
// stable `kind` key (one of the six below) and hands it here with the parsed payload.
//
// Terminal consumer: every mapping is best-effort and TOLERANT of payload-shape drift
// across the producing services (01-auth, 13-order, 09-payment, 10-wallet). We extract
// the opaque user id + a natural dedup id defensively from the common field spellings;
// an event we cannot attribute to a user returns null (no owner → no inbox row).
import type { NotificationCategory } from '../types';

// The six logical event kinds this service consumes (architecture §10). The consumer
// maps a configured Kafka TOPIC NAME → one of these, so renaming a topic in env never
// breaks the mapping.
export type EventKind =
  | 'user.created'
  | 'order.placed'
  | 'payment.settled'
  | 'kyc.approved'
  | 'kyc.rejected'
  | 'wallet.cashback_granted';

// The materialized notification minus the fields the consumer stamps (userId/read/createdAt).
export interface NotificationDraft {
  kind: string;            // welcome | order_placed | payment_settled | kyc_approved | kyc_rejected | cashback
  category: NotificationCategory;
  title_bn: string;
  title_en: string;
  body_bn: string;
  body_en: string;
  deepLink: string;
}

export interface MappedEvent {
  userId: string;          // the opaque inbox owner
  dedupKey: string;        // natural key → absorbs Kafka at-least-once redelivery (24h window)
  draft: NotificationDraft;
}

// ── defensive field pluckers (events arrive as already-parsed JSON objects) ──────────
function str(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  if (typeof v === 'string') return v || null;
  if (typeof v === 'number' || typeof v === 'bigint') return String(v);
  return null;
}
function pick(o: any, ...keys: string[]): string | null {
  if (!o || typeof o !== 'object') return null;
  for (const k of keys) {
    const v = str(o[k]);
    if (v) return v;
  }
  return null;
}
// Some producers wrap the domain payload under `data`/`payload`; look there too.
function body(value: any): any {
  if (value && typeof value === 'object') {
    if (value.data && typeof value.data === 'object') return value.data;
    if (value.payload && typeof value.payload === 'object') return value.payload;
  }
  return value;
}

const userIdOf = (b: any): string | null =>
  pick(b, 'user_id', 'userId', 'customer_id', 'customerId', 'buyer_id', 'buyerId', 'uid', 'sub');

// Map a (kind, payload) → a bilingual draft + owner + dedup key, or null if unmappable.
export function mapEvent(kind: EventKind, value: any): MappedEvent | null {
  const b = body(value);
  const userId = userIdOf(b);
  if (!userId) return null;

  // Prefer an explicit producer event id for dedup; fall back to a per-kind natural key.
  const explicitId = pick(b, 'event_id', 'eventId', 'id');

  switch (kind) {
    case 'user.created': {
      return {
        userId,
        dedupKey: explicitId || `user:${userId}`,
        draft: {
          kind: 'welcome',
          category: 'promotional',
          title_bn: 'দোকানদারে স্বাগতম',
          title_en: 'Welcome to DOKANDAR',
          body_bn: 'আপনার অ্যাকাউন্ট তৈরি হয়েছে। কেনাকাটা শুরু করুন!',
          body_en: 'Your account is ready. Start shopping!',
          deepLink: '/',
        },
      };
    }
    case 'order.placed': {
      const orderId = pick(b, 'order_id', 'orderId', 'id') || 'unknown';
      return {
        userId,
        dedupKey: explicitId || `order:${orderId}`,
        draft: {
          kind: 'order_placed',
          category: 'transactional',
          title_bn: 'অর্ডার নেওয়া হয়েছে',
          title_en: 'Order placed',
          body_bn: `আপনার অর্ডার #${orderId} সফলভাবে নেওয়া হয়েছে।`,
          body_en: `Your order #${orderId} has been placed.`,
          deepLink: `/orders/${orderId}`,
        },
      };
    }
    case 'payment.settled': {
      const orderId = pick(b, 'order_id', 'orderId') || '';
      const payId = pick(b, 'payment_id', 'paymentId', 'intent_id', 'intentId') || orderId || 'unknown';
      return {
        userId,
        dedupKey: explicitId || `payment:${payId}`,
        draft: {
          kind: 'payment_settled',
          category: 'transactional',
          title_bn: 'পেমেন্ট সম্পন্ন',
          title_en: 'Payment received',
          body_bn: orderId ? `অর্ডার #${orderId}-এর পেমেন্ট নিশ্চিত হয়েছে।` : 'আপনার পেমেন্ট নিশ্চিত হয়েছে।',
          body_en: orderId ? `Payment for order #${orderId} is confirmed.` : 'Your payment is confirmed.',
          deepLink: orderId ? `/orders/${orderId}` : '/wallet',
        },
      };
    }
    case 'kyc.approved': {
      return {
        userId,
        dedupKey: explicitId || `kyc:approved:${userId}`,
        draft: {
          kind: 'kyc_approved',
          category: 'transactional',
          title_bn: 'কেওয়াইসি অনুমোদিত',
          title_en: 'KYC approved',
          body_bn: 'আপনার পরিচয় যাচাই সম্পন্ন হয়েছে।',
          body_en: 'Your identity verification is complete.',
          deepLink: '/account/kyc',
        },
      };
    }
    case 'kyc.rejected': {
      const reason = pick(b, 'reason', 'rejection_reason') || '';
      return {
        userId,
        dedupKey: explicitId || `kyc:rejected:${userId}`,
        draft: {
          kind: 'kyc_rejected',
          category: 'transactional',
          title_bn: 'কেওয়াইসি বাতিল',
          title_en: 'KYC rejected',
          body_bn: reason ? `আপনার পরিচয় যাচাই বাতিল হয়েছে: ${reason}` : 'আপনার পরিচয় যাচাই বাতিল হয়েছে। আবার চেষ্টা করুন।',
          body_en: reason ? `Your identity verification was rejected: ${reason}` : 'Your identity verification was rejected. Please try again.',
          deepLink: '/account/kyc',
        },
      };
    }
    case 'wallet.cashback_granted': {
      const txnId = pick(b, 'transaction_id', 'transactionId', 'entry_id', 'entryId') || '';
      const amountPaisa = pick(b, 'amount_paisa', 'amountPaisa', 'amount');
      const amountBdt = amountPaisa && /^\d+$/.test(amountPaisa) ? (parseInt(amountPaisa, 10) / 100).toFixed(2) : null;
      return {
        userId,
        dedupKey: explicitId || (txnId ? `cashback:${txnId}` : `cashback:${userId}:${amountPaisa || '0'}`),
        draft: {
          kind: 'cashback',
          category: 'transactional',
          title_bn: 'ক্যাশব্যাক যোগ হয়েছে',
          title_en: 'Cashback credited',
          body_bn: amountBdt ? `আপনার ওয়ালেটে ৳${amountBdt} ক্যাশব্যাক যোগ হয়েছে।` : 'আপনার ওয়ালেটে ক্যাশব্যাক যোগ হয়েছে।',
          body_en: amountBdt ? `৳${amountBdt} cashback has been added to your wallet.` : 'Cashback has been added to your wallet.',
          deepLink: '/wallet',
        },
      };
    }
    default:
      return null;
  }
}
