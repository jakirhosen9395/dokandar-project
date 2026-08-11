import Link from "next/link";
import { SiteHeader } from "@/components/site-header";

export default function NotFound() {
  return (
    <>
      <SiteHeader />
      <main className="mx-auto flex max-w-md flex-col items-center justify-center px-4 py-24 text-center">
        <h1 className="text-3xl font-bold">404</h1>
        <p className="mt-2 text-muted-foreground">This page could not be found.</p>
        <Link href="/" className="mt-6 rounded border border-border px-3 py-1.5 text-sm hover:bg-muted">Back to home</Link>
      </main>
    </>
  );
}
