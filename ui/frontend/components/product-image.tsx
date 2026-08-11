// GAP-5: products carry no image refs in the public payload. Instead of a blank box, render a
// deterministic, branded placeholder (stable colour from the id + the product's initial) so the UI
// looks intentional. Pure (no hooks) → works in SSR grids and detail pages.
const COLORS = [
  "from-rose-400 to-orange-400",
  "from-blue-400 to-cyan-400",
  "from-violet-400 to-fuchsia-400",
  "from-emerald-400 to-teal-400",
  "from-amber-400 to-yellow-400",
  "from-indigo-400 to-sky-400",
  "from-pink-400 to-rose-400",
  "from-teal-400 to-green-400",
];

function hash(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return Math.abs(h);
}

export function ProductImage({ id, name, className = "", textClass = "text-2xl" }: { id: string; name?: string | null; className?: string; textClass?: string }) {
  const color = COLORS[hash(id || name || "x") % COLORS.length];
  const initial = (name?.trim()?.[0] ?? "🛍").toUpperCase();
  return (
    <div aria-hidden className={`flex items-center justify-center bg-gradient-to-br ${color} ${className}`}>
      <span className={`font-bold text-white/90 ${textClass}`}>{initial}</span>
    </div>
  );
}
