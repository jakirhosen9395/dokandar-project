import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import dkd_platform as p
from dkd_platform.ids import DID, PPID, GPID
from dkd_platform.money import Money
from dkd_platform.errors import error_code, ContextSlug, ValidationError
from dkd_platform.topics import KafkaTopics, TOPIC_META, RabbitQueues


def test_provenance():
    assert p.CONTRACT_VERSION == "1.0.0"


def test_ids_typed_and_validated():
    _V7 = "0198c0de-0000-7000-8000-000000000001"  # a canonical UUIDv7 body
    d = DID("did:dokandar:" + _V7)
    assert str(d) == "did:dokandar:" + _V7 and DID.IMMUTABLE and DID.OWNER_CONTEXT == 1
    try:
        PPID("did:dokandar:" + _V7)  # wrong prefix
        assert False
    except ValueError:
        pass
    # GPID permits a leading category segment before the trailing UUIDv7
    assert GPID("GP-rice-" + _V7).value.startswith("GP-")


def test_topics_count_and_meta():
    assert len(TOPIC_META) == 59
    m = TOPIC_META["custody.passport.CustodyInitialized.v1"]
    assert m.producer == 3 and m.key == "PPID"
    assert len([q for q in dir(RabbitQueues) if not q.startswith("_")]) == 10


def test_money_int64_only():
    assert Money(5000).poisha == 5000
    try:
        Money(50.0); assert False
    except TypeError:
        pass


def test_error_taxonomy():
    code = error_code("finance", "idempotency", "duplicate_key")
    assert code == "dokandar.finance.idempotency.duplicate_key"
    try:
        error_code("frobnicate", "x", "y"); assert False
    except ValueError:
        pass
    assert ContextSlug.FINANCE == "finance"
