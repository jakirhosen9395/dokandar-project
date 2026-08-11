// Lossless money-on-the-wire serialization (CC-CONS-03).
//
// Money is bigint poisha internally. `JSON.stringify` cannot render a bigint (it throws), and the
// previous work-around (`Number(bigint)`) silently downcast poisha to IEEE-754 float64 on the
// Published-Language wire — corrupting any value > 2^53 (finance/analytics consume these payloads).
// This serializer renders every bigint as a bare JSON *integer literal* (e.g. 13510798882111491),
// which Java `long` and Python `int` consumers parse exactly. Strings would break their existing
// number deserializers, so an integer literal — not a quoted string — is the canonical wire form
// (money = int64 poisha, DM-TYPE-001 / EF-FIT-7).
//
// Technique: the replacer swaps each bigint for a unique private-use-area sentinel string
// (U+E000…U+E001 delimited), which JSON.stringify passes through literally — it only escapes control
// chars, `"` and `\`. We then strip the surrounding quotes to leave a raw integer literal. The
// sentinels are non-ASCII, so they can never collide with a real payload field (all IDs, units and
// reasons are ASCII), and never with the digit strings we splice in.
const OPEN = String.fromCharCode(0xe000);
const CLOSE = String.fromCharCode(0xe001);

/**
 * A pre-serialized JSON fragment to be spliced verbatim into the output — used by the idempotency
 * cache to replay a stored response body (which may carry >2^53 poisha) without a lossy JSON.parse.
 */
export class RawJson {
  readonly json: string;
  constructor(json: string) {
    this.json = json;
  }
}

export function stringifyWithBigInt(value: unknown): string {
  const rawByToken = new Map<string, string>();
  let seq = 0;
  const withSentinels = JSON.stringify(value, (_key, v) => {
    if (typeof v === "bigint") {
      const token = `${OPEN}${seq}${CLOSE}`;
      rawByToken.set(token, v.toString());
      seq += 1;
      return token;
    }
    if (v instanceof RawJson) {
      const token = `${OPEN}${seq}${CLOSE}`;
      rawByToken.set(token, v.json);
      seq += 1;
      return token;
    }
    return v;
  });
  if (withSentinels === undefined) return withSentinels as unknown as string;
  let out = withSentinels;
  for (const [token, raw] of rawByToken) {
    // Function replacement: emits `raw` literally (bigint digits, or a whole JSON fragment) with no
    // `$`-pattern interpretation. The quotes around the sentinel are stripped, leaving a bare value.
    out = out.replace(`"${token}"`, () => raw);
  }
  return out;
}
