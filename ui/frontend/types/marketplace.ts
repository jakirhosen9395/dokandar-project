/** Shapes captured from live backend responses (catalog/search/cart). Some fields are loose where the
 *  OpenAPI spec doesn't document the response body. */

export interface SearchItem {
  product_id: string;
  shop_id: string | null;
  category_id: string | null;
  name_en: string;
  name_bn: string;
  slug?: string | null;
  list_price_minor: number | null;
  sale_price_minor: number | null;
  rating_avg: number | null;
  rating_count: number | null;
  in_stock: boolean;
}

export interface SearchResponse {
  total: number;
  items: SearchItem[];
  facets?: { category?: Record<string, number> };
  page?: number;
  size?: number;
  locale?: string;
}

export interface Category {
  category_id: string;
  name_en: string;
  name_bn: string;
  slug?: string | null;
  parent_id?: string | null;
  children?: Category[];
}

export interface ProductVariant {
  id: string;
  [k: string]: unknown;
}

export interface Product {
  id: string;
  owner_id?: string;
  name_en: string;
  name_bn: string;
  description_en?: string;
  description_bn?: string;
  brand?: string | null;
  sku?: string | null;
  category_id?: string | null;
  list_price_minor?: number | null;
  sale_price_minor?: number | null;
  status?: string;
  variants?: ProductVariant[];
}

export interface CartLine {
  line_id?: string;
  lineId?: string;
  product_id: string;
  variant_id?: string;
  shop_id?: string;
  quantity: number;
  [k: string]: unknown;
}

export interface Cart {
  items?: CartLine[];
  lines?: CartLine[];
  subtotal_minor?: number;
  [k: string]: unknown;
}
