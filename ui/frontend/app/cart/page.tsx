import { SiteHeader } from "@/components/site-header";
import { CartView } from "@/features/cart/cart-view";

export const dynamic = "force-dynamic";

export default function CartPage() {
  return (
    <>
      <SiteHeader />
      <main className="mx-auto max-w-3xl px-4 py-6">
        <h1 className="mb-4 text-xl font-semibold">Your cart</h1>
        <CartView />
      </main>
    </>
  );
}
