# Thoth — Project Rules

## Core Mechanics Are Sacred

The file `Game core Mechanics.md` is the authoritative source of truth for all gameplay mechanics. **Never** add, remove, or alter any core mechanic unless the user explicitly updates that document first. This includes:

- The spell combination system (Trigger + Manifestation + Support chains)
- Casting rules (movement speed, chain breaking, aura stacking, release behavior)
- The Concentration Meter system
- Stacking rules (within-chain and between-spell)
- Buff/debuff formulas and diminishing returns curves
- Magic circle visualization behavior
- Trigger magic definitions (Fire, Water, Earth, Wind)
- Supporting magic definitions (Nature, Necrotic, Time, Space)
- Aim assist scaling rules

When implementing features, always cross-reference `Game core Mechanics.md` to ensure the implementation matches the spec exactly. If a requested feature would conflict with or alter a core mechanic, flag it to the user before proceeding.

## Versioning and Branching

All work follows **semantic versioning** `vX.Y.Z`:

- **X (Major):** Main release milestones — new content drops or large-scale code revamps. The game ships as `1.0.0`.
- **Y (Minor):** Feature additions — new menu options, new spells, new UI screens, etc.
- **Z (Patch):** Day-to-day work — bug fixes, small tweaks, minor additions that don't qualify as a feature.

### Branch naming

- Feature branches: `v0.Y.0-description` (e.g., `v0.2.0-pause-menu`)
- Patch branches: `v0.Y.Z-description` (e.g., `v0.1.1-fix-projectile-speed`)
- All branches are created from and PR'd back into `master`.

### Task cataloging

When starting work, identify whether it's a minor (Y) or patch (Z) increment based on the criteria above, name the branch accordingly, and announce the version label to the user.

## Testing

### PR Testing Plans

Every PR must include a **Testing Plan** in the PR body before merging. The plan should list concrete steps the user can follow in-editor or in-game to verify the changes work as intended. Format:

- A checklist of things to test, specific to what the PR changes
- Expected behavior for each item
- Any edge cases worth checking

Do not merge a PR until the user has reviewed the testing plan.

### Test Regression

When running tests (automated or manual) or creating new tests:

- **All previous tests must still pass.** Never ignore or skip a failing pre-existing test.
- If a new change causes an old test to fail, fix the regression before proceeding — do not merge with known failures.
- When adding new tests, run the full existing test suite first to establish a baseline, then verify again after changes.

## General

- Add brief comments in code explaining *why* things work, not just what they do.
- Explain UE5/C++ concepts in beginner-friendly terms.
- Prefer teaching moments — flag things the user could try fixing themselves when appropriate.
