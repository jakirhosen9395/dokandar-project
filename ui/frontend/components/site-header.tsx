"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState, type FormEvent, type KeyboardEvent } from "react";
import { useUiStore } from "@/stores/ui";
import { useAuth } from "@/hooks/use-auth";

interface Suggestion {
  text: string;
  product_id?: string;
}

export function SiteHeader() {
  const router = useRouter();
  const locale = useUiStore((s) => s.locale);
  const setLocale = useUiStore((s) => s.setLocale);
  const { isAuthenticated, user } = useAuth();
  const [q, setQ] = useState("");
  const [suggestions, setSuggestions] = useState<Suggestion[]>([]);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const boxRef = useRef<HTMLDivElement>(null);

  // Debounced autocomplete. Search is public at the gateway, so no Bearer is needed —
  // the request still goes through the BFF proxy (/api/gw). Stale requests are aborted.
  useEffect(() => {
    const term = q.trim();
    if (term.length < 2) {
      setSuggestions([]);
      setOpen(false);
      return;
    }
    const ctrl = new AbortController();
    const t = setTimeout(async () => {
      try {
        const r = await fetch(`/api/gw/search/autocomplete?q=${encodeURIComponent(term)}&locale=${locale}`, { signal: ctrl.signal });
        if (!r.ok) return;
        const data = (await r.json()) as { suggestions?: Suggestion[] };
        setSuggestions((data.suggestions ?? []).slice(0, 8));
        setActive(-1);
        setOpen(true);
      } catch {
        /* aborted or network error — silently ignore (autocomplete is best-effort) */
      }
    }, 200);
    return () => {
      clearTimeout(t);
      ctrl.abort();
    };
  }, [q, locale]);

  // Close the dropdown on outside click.
  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, []);

  function go(term: string) {
    setOpen(false);
    router.push(term.trim() ? `/search?q=${encodeURIComponent(term.trim())}` : "/search");
  }

  function pick(s: Suggestion) {
    setOpen(false);
    setQ(s.text);
    if (s.product_id) router.push(`/product/${s.product_id}`);
    else go(s.text);
  }

  function onSearch(e: FormEvent) {
    e.preventDefault();
    if (open && active >= 0 && suggestions[active]) {
      pick(suggestions[active]);
      return;
    }
    go(q);
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (!open || suggestions.length === 0) return;
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setActive((i) => Math.min(i + 1, suggestions.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActive((i) => Math.max(i - 1, -1));
    } else if (e.key === "Escape") {
      setOpen(false);
    }
  }

  return (
    <header className="sticky top-0 z-40 border-b border-border bg-background/95 backdrop-blur">
      <div className="mx-auto flex max-w-7xl items-center gap-3 px-4 py-2.5">
        <Link href="/" className="shrink-0 text-lg font-bold">DOKANDAR</Link>
        <div ref={boxRef} className="relative flex-1">
          <form onSubmit={onSearch} role="search" className="flex items-center">
            <input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              onKeyDown={onKeyDown}
              onFocus={() => suggestions.length > 0 && setOpen(true)}
              placeholder="Search products…"
              aria-label="Search products"
              role="combobox"
              aria-expanded={open}
              aria-autocomplete="list"
              aria-controls="search-suggestions"
              autoComplete="off"
              className="w-full rounded-l-md border border-border bg-background px-3 py-1.5 outline-none focus:ring-2 focus:ring-ring"
            />
            <button className="rounded-r-md border border-l-0 border-border bg-foreground px-3 py-1.5 text-sm font-medium text-background">
              Search
            </button>
          </form>
          {open && suggestions.length > 0 ? (
            <ul
              id="search-suggestions"
              role="listbox"
              className="absolute left-0 right-0 top-full z-50 mt-1 overflow-hidden rounded-md border border-border bg-background shadow-lg"
            >
              {suggestions.map((s, i) => (
                <li
                  key={s.product_id ?? s.text}
                  role="option"
                  aria-selected={i === active}
                  onMouseEnter={() => setActive(i)}
                  onMouseDown={(e) => {
                    e.preventDefault();
                    pick(s);
                  }}
                  className={`cursor-pointer px-3 py-2 text-sm ${i === active ? "bg-muted" : "hover:bg-muted"}`}
                >
                  {s.text}
                </li>
              ))}
            </ul>
          ) : null}
        </div>
        <nav className="flex shrink-0 items-center gap-3 text-sm">
          <button type="button" onClick={() => setLocale(locale === "en" ? "bn" : "en")} className="text-muted-foreground hover:underline">
            {locale === "en" ? "বাংলা" : "EN"}
          </button>
          <Link href="/cart" className="hover:underline">Cart</Link>
          {isAuthenticated ? (
            <Link href="/account" className="hover:underline">{user?.name?.split(" ")[0] ?? "Account"}</Link>
          ) : (
            <Link href="/login" className="hover:underline">Log in</Link>
          )}
        </nav>
      </div>
    </header>
  );
}
