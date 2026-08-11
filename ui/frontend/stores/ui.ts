/** UI-only client state (locale). Persisted in a plain cookie (not a token) so SSR + the next visit agree. */
import { create } from "zustand";

export type Locale = "en" | "bn";

function initialLocale(): Locale {
  if (typeof document === "undefined") return "en";
  return (document.cookie.match(/(?:^|; )locale=(bn|en)/)?.[1] as Locale) || "en";
}

interface UiState {
  locale: Locale;
  setLocale: (l: Locale) => void;
}

export const useUiStore = create<UiState>((set) => ({
  locale: initialLocale(),
  setLocale: (locale) => {
    if (typeof document !== "undefined") document.cookie = `locale=${locale};path=/;max-age=31536000;samesite=lax`;
    set({ locale });
  },
}));
