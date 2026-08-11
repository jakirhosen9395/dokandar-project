// Domain types for the 14-notification inbox. Mirrors §3.1 of architecture.md
// (the MongoDB inbox shape). Cross-service ids (userId) are opaque strings.

export type Channel = 'sms' | 'push' | 'email' | 'whatsapp';

export type NotificationCategory = 'transactional' | 'promotional';

// notifications — one document per delivered notification (bilingual bn/en).
export interface Notification {
  userId: string;
  kind: string;                 // welcome | order_placed | payment_settled | kyc_approved | cashback | …
  category: NotificationCategory;
  title_bn: string;
  title_en: string;
  body_bn: string;
  body_en: string;
  deepLink: string;
  read: boolean;
  createdAt: Date;
}

// notification_preferences — per user, per channel opt-in.
export interface Preferences {
  userId: string;
  channels: {
    sms: boolean;
    push: boolean;
    email: boolean;
    whatsapp: boolean;
  };
}

// notification_dispatch_log — external send audit (90-day TTL on tsDate).
// Records channel + provider id only — never the OTP code or notification body.
export interface DispatchLogEntry {
  userId: string;
  channel: Channel;
  provider: string;             // ssl_wireless | whatsapp_cloud | fcm | aws_ses
  providerId: string;
  status: string;               // sent | failed | …
  tsDate: Date;
}
