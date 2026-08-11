"use client";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuthStore } from "@/stores/auth";
import { addToCart, getCart, removeItem, updateQty } from "@/lib/services/cart";
import type { Cart, CartLine } from "@/types/marketplace";

const lineId = (l: CartLine) => l.line_id ?? l.lineId ?? "";
const lines = (c: Cart | null | undefined): CartLine[] => c?.items ?? c?.lines ?? [];

export function useCart() {
  const accessToken = useAuthStore((s) => s.accessToken);
  const qc = useQueryClient();

  const query = useQuery({ queryKey: ["cart"], queryFn: getCart, enabled: !!accessToken });
  const refresh = () => qc.invalidateQueries({ queryKey: ["cart"] });

  const add = useMutation({
    mutationFn: addToCart,
    onSuccess: (c) => (c ? qc.setQueryData(["cart"], c) : refresh()),
  });

  // optimistic quantity update with rollback
  const update = useMutation({
    mutationFn: ({ id, quantity }: { id: string; quantity: number }) => updateQty(id, quantity),
    onMutate: async ({ id, quantity }) => {
      await qc.cancelQueries({ queryKey: ["cart"] });
      const prev = qc.getQueryData<Cart>(["cart"]);
      if (prev) {
        const patched = { ...prev, items: lines(prev).map((l) => (lineId(l) === id ? { ...l, quantity } : l)) };
        qc.setQueryData(["cart"], patched);
      }
      return { prev };
    },
    onError: (_e, _v, ctx) => ctx?.prev && qc.setQueryData(["cart"], ctx.prev),
    onSettled: refresh,
  });

  const remove = useMutation({
    mutationFn: (id: string) => removeItem(id),
    onMutate: async (id) => {
      await qc.cancelQueries({ queryKey: ["cart"] });
      const prev = qc.getQueryData<Cart>(["cart"]);
      if (prev) qc.setQueryData(["cart"], { ...prev, items: lines(prev).filter((l) => lineId(l) !== id) });
      return { prev };
    },
    onError: (_e, _v, ctx) => ctx?.prev && qc.setQueryData(["cart"], ctx.prev),
    onSettled: refresh,
  });

  return { cart: query.data ?? null, items: lines(query.data), isLoading: query.isLoading, add, update, remove };
}
