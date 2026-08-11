# Release Guide

Releases are cut from `main` after a green pipeline. Artifacts are **promoted by digest**, never
rebuilt per environment.

## Steps

1. **Sync contracts (if needed).** Update `contracts/` to the target `dkd-contracts-spine` tag; commit
   the new `spine.lock.yaml`. `dkdgen verify` must pass.
2. **Regenerate.** `bash scripts/generate.sh all` — commit the SDK changes (the drift gate enforces this).
3. **Version.** Bump `VERSION` per [versioning](versioning.md); update `CHANGELOG.md`.
4. **Pipeline.** Green required: governance · generator tests · contract-compat · generator-drift ·
   `sdk:{python,go,java,typescript}` build+test.
5. **Tag.** `vX.Y.Z` on the merge commit.
6. **Publish (per language).** The publish stage stamps live provenance (`DKDGEN_BUILD_TIME`,
   `DKDGEN_BUILD_COMMIT=$CI_COMMIT_SHORT_SHA`) and pushes packages to the sovereign registry:
   - Python → wheel/sdist · Go → module tag · TS → npm package · Java → Maven artifact.

## Conservative discipline

Money/contract/ordering-key changes force a **MAJOR**. SBOM + signing on published artifacts. Only
signed, attested artifacts are admitted downstream.
