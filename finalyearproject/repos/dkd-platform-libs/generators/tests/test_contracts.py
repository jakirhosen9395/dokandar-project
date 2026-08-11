"""Parser/IR tests — assert the IR matches the frozen contracts exactly (no drift, no fabrication)."""
import os
import sys
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # generators/
sys.path.insert(0, ROOT)
CONTRACTS = os.path.join(os.path.dirname(ROOT), "contracts")

from dkdgen import load, verify_freeze, ContractError  # noqa: E402
from dkdgen.ir import CONTEXTS, NEEDS_INFO            # noqa: E402


@pytest.fixture(scope="module")
def c():
    return load(CONTRACTS)


def test_freeze_integrity_passes(c):
    assert c.spine_version == "1.0.0"


def test_freeze_drift_is_rejected(tmp_path):
    # copy contracts, mutate one byte, expect ContractError
    import shutil
    for f in os.listdir(CONTRACTS):
        shutil.copy(os.path.join(CONTRACTS, f), tmp_path / f)
    p = tmp_path / "ids.yaml"
    p.write_text(p.read_text() + "\n# tampered\n")
    with pytest.raises(ContractError):
        verify_freeze(str(tmp_path))


def test_identifiers_match_contract(c):
    ids = {i.id for i in c.identifiers}
    assert ids == {"DID", "PPID", "GPID", "ORD", "TRD", "WLT", "ESC", "TXN", "SHP", "NTF", "MFSA"}
    did = next(i for i in c.identifiers if i.id == "DID")
    assert did.prefix == "did:dokandar:" and did.immutable is True and did.owner_ctx == 1


def test_topics_are_59_and_well_formed(c):
    assert len(c.topics) == 59
    assert len({t.name for t in c.topics}) == 59
    custody = [t for t in c.topics if t.context == "custody"]
    assert custody and all(t.producer == 3 for t in custody)        # R1 sole writer
    # read-only contexts produce nothing
    producers = {t.producer for t in c.topics}
    assert producers.isdisjoint({4, 5, 12})


def test_queues_are_10_intra_context(c):
    assert len(c.queues) == 10
    for q in c.queues:
        assert q.name.startswith(CONTEXTS[q.context] + ".")


def test_schema_subjects_one_per_topic_all_needs_info(c):
    assert len(c.schema_subjects) == len(c.topics) == 59
    assert {s.subject for s in c.schema_subjects} == {t.name for t in c.topics}
    assert all(s.schema_status == NEEDS_INFO for s in c.schema_subjects)   # framework-only, by contract


def test_constants_present(c):
    ids = {k.id for k in c.constants}
    assert "COOLING_OFF_WINDOW" in ids and "ESCROW_ABANDON_TTL" in ids


def test_error_taxonomy_frozen_codes_empty(c):
    assert c.error_taxonomy.fmt == "dokandar.<context>.<category>.<reason>"
    assert "finance" in c.error_taxonomy.context_slugs
    assert c.error_taxonomy.codes == ()                                    # blocked: no codes in contract


def test_kyc_tiers_exhaustive(c):
    kyc = next(f for f in c.enum_families if f.family == "kyc_tiers")
    assert list(kyc.values) == ["V0", "V1", "V2", "V3"] and kyc.exhaustive is True


def test_money_is_int64_poisha(c):
    assert c.types.money_repr == "int64" and c.types.money_unit == "poisha"
