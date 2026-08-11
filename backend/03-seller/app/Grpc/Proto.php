<?php

namespace App\Grpc;

/**
 * Minimal protobuf wire encode/decode for the two tiny auth.proto messages
 * we call. Avoids pulling google/protobuf + generated stubs for a single
 * RPC — the grpc *extension* provides transport; this provides (de)serial.
 *
 *   LookupShopkeeperRequest  { string user_id = 1 }
 *   LookupShopkeeperResponse { bool exists=1; string role=2; string status=3; string owner_id=4 }
 */
final class Proto
{
    public static function encodeLookupRequest(string $userId): string
    {
        return self::stringField(1, $userId);
    }

    /** @return array{exists:bool,role:string,status:string,owner_id:string} */
    public static function decodeLookupResponse(string $b): array
    {
        $out = ['exists' => false, 'role' => '', 'status' => '', 'owner_id' => ''];
        $i = 0;
        $n = strlen($b);
        while ($i < $n) {
            [$tag, $i] = self::readVarint($b, $i);
            $field = $tag >> 3;
            $wire = $tag & 0x7;
            if ($wire === 0) { // varint
                [$val, $i] = self::readVarint($b, $i);
                if ($field === 1) {
                    $out['exists'] = $val !== 0;
                }
            } elseif ($wire === 2) { // length-delimited
                [$len, $i] = self::readVarint($b, $i);
                $s = substr($b, $i, $len);
                $i += $len;
                if ($field === 2) {
                    $out['role'] = $s;
                } elseif ($field === 3) {
                    $out['status'] = $s;
                } elseif ($field === 4) {
                    $out['owner_id'] = $s;
                }
            } elseif ($wire === 5) {
                $i += 4; // 32-bit, skip
            } elseif ($wire === 1) {
                $i += 8; // 64-bit, skip
            } else {
                break; // unknown wire type — stop
            }
        }
        return $out;
    }

    private static function stringField(int $field, string $val): string
    {
        return self::varint(($field << 3) | 2) . self::varint(strlen($val)) . $val;
    }

    private static function varint(int $v): string
    {
        $o = '';
        do {
            $b = $v & 0x7f;
            $v >>= 7;
            if ($v) {
                $b |= 0x80;
            }
            $o .= chr($b);
        } while ($v);
        return $o;
    }

    /** @return array{0:int,1:int} [value, newOffset] */
    private static function readVarint(string $b, int $i): array
    {
        $r = 0;
        $s = 0;
        $n = strlen($b);
        while ($i < $n) {
            $c = ord($b[$i++]);
            $r |= ($c & 0x7f) << $s;
            if (! ($c & 0x80)) {
                break;
            }
            $s += 7;
        }
        return [$r, $i];
    }
}
