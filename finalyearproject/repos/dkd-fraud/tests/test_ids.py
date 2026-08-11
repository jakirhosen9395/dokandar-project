"""UUID v7 shape and DID validation."""

from fraud import ids


def test_uuid7_shape_and_version_bits() -> None:
    u = ids.uuid7()
    parts = u.split("-")
    assert [len(p) for p in parts] == [8, 4, 4, 4, 12]
    assert parts[2][0] == "7"  # version nibble
    assert parts[3][0] in "89ab"  # RFC 4122 variant


def test_uuid7_time_ordered_prefix() -> None:
    a, b = ids.uuid7(), ids.uuid7()
    assert a[:8] <= b[:8]


def test_signal_id_prefix() -> None:
    assert ids.new_signal_id().startswith("FSG-")


def test_is_did() -> None:
    assert ids.is_did("did:dokandar:019f2406-01d2-7551-814f-09321418b8ec")
    assert not ids.is_did("did:dokandar:")
    assert not ids.is_did("WLT-x")
    assert not ids.is_did(None)
