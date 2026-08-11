"use client";
import { useUiStore } from "@/stores/ui";

const MESSAGES = {
  en: {
    login: "Log in", signup: "Sign up", phone: "Phone number", sendCode: "Send code",
    code: "Verification code", verify: "Verify", name: "Full name", resend: "Resend code",
    otpSent: "We sent a code to", invalid: "Invalid code — please try again.",
    forbidden: "403 — Forbidden", forbiddenMsg: "You don't have access to this area.",
    loggingOut: "Logging out…", backHome: "Back to home", haveAccount: "Already have an account? Log in",
    noAccount: "New here? Sign up",
  },
  bn: {
    login: "লগ ইন", signup: "সাইন আপ", phone: "ফোন নম্বর", sendCode: "কোড পাঠান",
    code: "যাচাই কোড", verify: "যাচাই করুন", name: "পুরো নাম", resend: "আবার পাঠান",
    otpSent: "কোড পাঠানো হয়েছে", invalid: "ভুল কোড — আবার চেষ্টা করুন।",
    forbidden: "৪০৩ — নিষিদ্ধ", forbiddenMsg: "এই অংশে আপনার অ্যাক্সেস নেই।",
    loggingOut: "লগ আউট হচ্ছে…", backHome: "হোমে ফিরুন", haveAccount: "অ্যাকাউন্ট আছে? লগ ইন করুন",
    noAccount: "নতুন? সাইন আপ করুন",
  },
} as const;

export type MsgKey = keyof (typeof MESSAGES)["en"];

export function useT() {
  const locale = useUiStore((s) => s.locale);
  const setLocale = useUiStore((s) => s.setLocale);
  return {
    t: (k: MsgKey) => MESSAGES[locale][k] ?? k,
    locale,
    setLocale,
  };
}
