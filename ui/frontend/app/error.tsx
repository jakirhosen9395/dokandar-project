"use client";
import { useEffect } from "react";
import Link from "next/link";

export default function Error({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    // Surfaced to the console; Elastic RUM captures unhandled errors automatically when configured.
    console.error(error);
  }, [error]);

  return (
    <div className="mx-auto flex max-w-md flex-col items-center justify-center px-4 py-24 text-center">
      <h1 className="text-2xl font-bold">Something went wrong</h1>
      <p className="mt-2 text-sm text-muted-foreground">An unexpected error occurred. You can retry, or go back home.</p>
      {error.digest && <p className="mt-1 text-xs text-muted-foreground">ref: {error.digest}</p>}
      <div className="mt-6 flex gap-3">
        <button onClick={reset} className="rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background">Retry</button>
        <Link href="/" className="rounded-md border border-border px-4 py-2 text-sm hover:bg-muted">Home</Link>
      </div>
    </div>
  );
}
