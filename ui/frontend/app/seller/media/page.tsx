"use client";
import { useState } from "react";
import { RemediationCard } from "@/components/remediation-card";

interface Draft { id: string; name: string; url: string }

// GAP-15/16: the media service can't round-trip through the gateway, so this is a LOCAL-ONLY staging
// queue (object-URL previews). Nothing is uploaded and no internal storage URL is touched — the publish
// action is explicitly blocked. Honest Category-B experience: stage now, upload when the service exists.
export default function SellerMedia() {
  const [drafts, setDrafts] = useState<Draft[]>([]);

  function onPick(files: FileList | null) {
    if (!files) return;
    const next: Draft[] = [];
    Array.from(files).forEach((f, i) => {
      if (f.type.startsWith("image/")) next.push({ id: `${f.name}-${i}-${f.size}`, name: f.name, url: URL.createObjectURL(f) });
    });
    setDrafts((d) => [...d, ...next]);
  }
  function remove(id: string) {
    setDrafts((d) => d.filter((x) => {
      if (x.id === id) URL.revokeObjectURL(x.url);
      return x.id !== id;
    }));
  }

  return (
    <div className="space-y-5">
      <h1 className="text-xl font-semibold">Media library</h1>

      <section className="rounded-lg border border-border p-4">
        <h2 className="mb-2 font-medium">Upload queue <span className="text-sm font-normal text-muted-foreground">(local drafts)</span></h2>
        <label className="inline-block cursor-pointer rounded-md border border-border px-3 py-1.5 text-sm hover:bg-muted">
          + Add images
          <input type="file" accept="image/*" multiple className="hidden" onChange={(e) => onPick(e.target.files)} />
        </label>
        {drafts.length > 0 && (
          <ul className="mt-3 grid grid-cols-3 gap-3 sm:grid-cols-4">
            {drafts.map((d) => (
              <li key={d.id} className="relative">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={d.url} alt={d.name} className="aspect-square w-full rounded-md object-cover" />
                <button onClick={() => remove(d.id)} aria-label={`Remove ${d.name}`} className="absolute right-1 top-1 rounded-full bg-black/60 px-1.5 text-xs text-white">×</button>
                <div className="mt-1 truncate text-xs text-muted-foreground">{d.name}</div>
              </li>
            ))}
          </ul>
        )}
        <button disabled className="mt-3 cursor-not-allowed rounded-md bg-muted px-4 py-2 text-sm font-medium text-muted-foreground">
          Upload to library — coming soon
        </button>
        <p className="mt-1 text-xs text-muted-foreground">Previewed locally only — nothing is uploaded. No internal storage URLs are used.</p>
      </section>

      <RemediationCard
        title="Media service unavailable"
        category="C"
        gap="GAP-15 / GAP-16"
        why="Image upload isn’t available yet. You can stage images locally above to prepare your listings; they’ll upload once the media service is enabled. Nothing is sent anywhere in the meantime."
        owner="Backend — media service (browser-reachable upload + listing)"
        recommendedFix="Expose media listing through the gateway, issue browser-reachable presigned URLs (or proxy uploads), and add a media reference to products."
        stillWorks={["Stage images locally above", "Product create/edit (text + pricing)"]}
      />
    </div>
  );
}
