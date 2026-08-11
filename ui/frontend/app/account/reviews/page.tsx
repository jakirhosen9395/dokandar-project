"use client";
import Link from "next/link";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { deleteReview, getMyReviews } from "@/lib/services/account";
import { useAuth } from "@/hooks/use-auth";

export default function ReviewsPage() {
  const qc = useQueryClient();
  const { user } = useAuth();
  const { data, isLoading } = useQuery({ queryKey: ["my-reviews"], queryFn: getMyReviews });
  const del = useMutation({ mutationFn: (id: string) => deleteReview(id), onSuccess: () => qc.invalidateQueries({ queryKey: ["my-reviews"] }) });
  const all = (data ?? []) as Record<string, unknown>[];
  // GAP-10: the list has no "mine" param. If rows carry an owner field, defensively scope to this user;
  // otherwise show what the API returns (it may already be caller-scoped).
  const hasOwnerField = all.some((r) => r.user_id || r.author_id || r.reviewer_id);
  const reviews = user?.id && hasOwnerField ? all.filter((r) => [r.user_id, r.author_id, r.reviewer_id].includes(user.id)) : all;

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">My reviews</h1>
      <p className="text-xs text-muted-foreground">
        Reviews are written from a purchased product page (verified-purchase gated). GAP-10: the backend list’s “mine” filter is unverified.
      </p>
      {isLoading ? (
        <div className="h-24 animate-pulse rounded bg-muted" />
      ) : reviews.length === 0 ? (
        <p className="py-6 text-center text-muted-foreground">You haven’t written any reviews yet.</p>
      ) : (
        <ul className="space-y-3">
          {reviews.map((r, i) => {
            const id = String(r.id ?? r.review_id ?? i);
            return (
              <li key={id} className="rounded-lg border border-border p-4 text-sm">
                <div className="flex items-start justify-between">
                  <div>
                    <div className="font-medium">★ {String(r.rating ?? "—")}{r.title ? ` · ${r.title}` : ""}</div>
                    {r.body ? <div className="text-muted-foreground">{String(r.body)}</div> : null}
                    {r.product_id ? <Link href={`/product/${r.product_id}`} className="text-xs underline">View product</Link> : null}
                  </div>
                  <button onClick={() => del.mutate(id)} className="text-xs text-red-500 hover:underline">Delete</button>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
