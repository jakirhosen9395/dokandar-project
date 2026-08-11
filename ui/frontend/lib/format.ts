/** Money is integer paisa on the backend (100 paisa = 1 BDT). Render as ৳. */
export function formatBDT(paisa: number | null | undefined, locale: "en" | "bn" = "en"): string {
  if (paisa == null) return "";
  const taka = paisa / 100;
  const n = taka.toLocaleString(locale === "bn" ? "bn-BD" : "en-BD", {
    minimumFractionDigits: taka % 1 === 0 ? 0 : 2,
    maximumFractionDigits: 2,
  });
  return `৳${n}`;
}

/** Pick the localized value (e.g. name_en / name_bn) with graceful fallback. */
export function pickLocale(en?: string | null, bn?: string | null, locale: "en" | "bn" = "en"): string {
  return (locale === "bn" ? bn : en) || en || bn || "";
}

export function discountPct(list?: number | null, sale?: number | null): number | null {
  if (!list || !sale || sale >= list) return null;
  return Math.round(((list - sale) / list) * 100);
}
