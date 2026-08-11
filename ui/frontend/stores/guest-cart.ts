"use client";
import { create } from "zustand";
import { persist } from "zustand/middleware";

// GAP-4 workaround: the gateway 401s guest-cart paths, so guests get a CLIENT-SIDE cart persisted in
// localStorage (the in-memory-only rule applies to TOKENS, not a guest cart). On login it merges into
// the server cart (cart/me) and clears. No backend change.
export interface GuestLine {
  shop_id: string;
  product_id: string;
  variant_id: string;
  quantity: number;
  name?: string;
  price_minor?: number;
}

interface GuestCartState {
  items: GuestLine[];
  add: (l: GuestLine) => void;
  setQty: (productId: string, variantId: string, quantity: number) => void;
  remove: (productId: string, variantId: string) => void;
  clear: () => void;
}

export const useGuestCart = create<GuestCartState>()(
  persist(
    (set) => ({
      items: [],
      add: (l) =>
        set((s) => {
          const i = s.items.findIndex((x) => x.product_id === l.product_id && x.variant_id === l.variant_id);
          if (i >= 0) {
            const items = [...s.items];
            items[i] = { ...items[i], quantity: items[i].quantity + l.quantity };
            return { items };
          }
          return { items: [...s.items, l] };
        }),
      setQty: (p, v, q) => set((s) => ({ items: s.items.map((x) => (x.product_id === p && x.variant_id === v ? { ...x, quantity: Math.max(1, q) } : x)) })),
      remove: (p, v) => set((s) => ({ items: s.items.filter((x) => !(x.product_id === p && x.variant_id === v)) })),
      clear: () => set({ items: [] }),
    }),
    { name: "dokandar-guest-cart" },
  ),
);
