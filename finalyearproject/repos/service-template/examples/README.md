# Examples

Generated sample services are produced by CI (`generate:samples`) — one per runtime — and compiled
against the real `dkd-platform-libs` v1.0.0. To generate one locally:

```bash
cd ../scaffold
python -m dkdscaffold new-service --name catalog-svc --context catalog --lang go     --out ../examples
python -m dkdscaffold new-service --name finance-svc --context finance --lang java    --out ../examples
python -m dkdscaffold new-service --name identity-svc --context identity --lang csharp --out ../examples
```

Generated service trees are intentionally not committed (they are build outputs; the scaffolder is the
source of truth). The CI `sample:*` jobs prove each runtime's generated service builds.
