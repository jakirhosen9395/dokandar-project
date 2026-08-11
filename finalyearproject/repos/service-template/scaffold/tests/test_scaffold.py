"""Scaffolder tests — generate a service per available runtime and assert the blueprint is realised."""
import os
import sys
import re
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCAFFOLD = os.path.dirname(HERE)
sys.path.insert(0, SCAFFOLD)

from dkdscaffold.blueprint import Service, RUNTIMES, CAPABILITIES  # noqa: E402
from dkdscaffold.runtimes import EMITTERS                          # noqa: E402

# Files every generated service must contain regardless of runtime (the shared ops contract).
COMMON_REQUIRED = [
    "README.md", "CHANGELOG.md", "VERSION", ".env.example",
    "Dockerfile", "docker-compose.yml", ".gitlab-ci.yml",
    "deploy/k8s/deployment.yaml", "deploy/k8s/service.yaml", "deploy/k8s/namespace.yaml",
    "docs/architecture.md", "docs/developer-guide.md",
]
FORBIDDEN = ("TODO", "FIXME", "PLACEHOLDER", "pseudo-code", "fake implementation")


def _emit(rt, tmp):
    svc = Service(name="catalog-svc", context="catalog", runtime=rt)
    out = os.path.join(str(tmp), rt)
    files = EMITTERS[rt].emit(svc, out)
    return out, files


@pytest.mark.parametrize("rt", sorted(EMITTERS.keys()))
def test_generates_common_ops_files(rt, tmp_path):
    out, files = _emit(rt, tmp_path)
    for req in COMMON_REQUIRED:
        assert os.path.isfile(os.path.join(out, req)), "%s missing %s" % (rt, req)
    # a Helm chart exists
    assert any("deploy/helm/" in f and f.endswith("Chart.yaml") for f in files), "%s: no Helm chart" % rt


@pytest.mark.parametrize("rt", sorted(EMITTERS.keys()))
def test_no_fabrication_markers(rt, tmp_path):
    out, files = _emit(rt, tmp_path)
    for f in files:
        txt = open(os.path.join(out, f), encoding="utf-8").read()
        for bad in FORBIDDEN:
            assert bad not in txt, "%s/%s contains forbidden %r" % (rt, f, bad)


@pytest.mark.parametrize("rt", sorted(EMITTERS.keys()))
def test_health_endpoints_present(rt, tmp_path):
    out, files = _emit(rt, tmp_path)
    blob = "".join(open(os.path.join(out, f), encoding="utf-8").read() for f in files)
    for ep in ("/health", "/ready", "/live", "/version"):
        assert ep in blob, "%s: endpoint %s not wired" % (rt, ep)


@pytest.mark.parametrize("rt", sorted(EMITTERS.keys()))
def test_version_consumes_sdk(rt, tmp_path):
    out, files = _emit(rt, tmp_path)
    blob = "".join(open(os.path.join(out, f), encoding="utf-8").read() for f in files)
    assert "ContractVersion" in blob or "contractVersion" in blob, "%s: /version must report SDK ContractVersion" % rt


@pytest.mark.parametrize("rt", sorted(EMITTERS.keys()))
def test_helm_deployment_has_probes(rt, tmp_path):
    out, _ = _emit(rt, tmp_path)
    dep = open(os.path.join(out, "deploy/helm/catalog-svc/templates/deployment.yaml"), encoding="utf-8").read()
    for probe in ("livenessProbe", "readinessProbe", "startupProbe"):
        assert probe in dep, "%s: Helm deployment missing %s" % (rt, probe)


def test_blueprint_is_complete():
    assert len(CAPABILITIES) >= 30
    assert set(RUNTIMES) == {"go", "java", "csharp", "python", "node"}
