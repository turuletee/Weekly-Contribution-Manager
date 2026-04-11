# General Project Rules

## Versioning and Branching

All work follows **semantic versioning** `vX.Y.Z`:

- **X (Major):** Main release milestones — new content drops or large-scale code revamps.
- **Y (Minor):** Feature additions — new menu options, new functionality, new UI screens, etc.
- **Z (Patch):** Day-to-day work — bug fixes, small tweaks, minor additions that don't qualify as a feature.

### Branch naming

- Feature branches: `vX.Y.0-description` (e.g., `v1.2.0-add-export`)
- Patch branches: `vX.Y.Z-description` (e.g., `v1.1.1-fix-typo`)
- All branches are created from and PR'd back into the main branch.

### Task cataloging

When starting work, identify whether it's a minor (Y) or patch (Z) increment based on the criteria above, name the branch accordingly, and announce the version label to the user.

## Code Consistency

Before implementing any new feature, read the existing codebase to understand its structure, patterns, and conventions. All new code must follow the same layout, naming conventions, file organization, and architectural patterns already established in the project. Do not introduce new patterns or structures unless explicitly asked — when in doubt, match what's already there.

## Testing

### Full Project Testing

Every change — whether a new feature, bug fix, or minor tweak — requires running the **full project test suite**, not just tests for the modified area. A change is not complete until the entire project passes.

### PR Testing Plans

Every PR must include a **Testing Plan** in the PR body before merging. The plan should list concrete steps to verify the changes work as intended. Format:

- A checklist of things to test, specific to what the PR changes
- Expected behavior for each item
- Any edge cases worth checking

Do not merge a PR until the user has reviewed the testing plan.

### Test Regression

When running tests (automated or manual) or creating new tests:

- **All previous tests must still pass.** Never ignore or skip a failing pre-existing test.
- If a new change causes an old test to fail, fix the regression before proceeding — do not merge with known failures.
- When adding new tests, run the full existing test suite first to establish a baseline, then verify again after changes.

### Test-Driven Development (TDD)

All new features and bug fixes follow a TDD approach:

1. **Write the test first** — before writing any implementation code, write a failing test that defines the expected behavior.
2. **Make it pass** — write the minimum code needed to make the test pass.
3. **Refactor** — clean up the implementation without breaking the test.

Never write implementation code for a feature that doesn't have a test driving it.

### Code Coverage

Maintain a minimum of **90% code coverage** across the project. When coverage drops below 90%, write the missing tests before moving on to new work. Coverage reports should be checked as part of every PR — do not merge if coverage regresses below the threshold.

### Test Quality

Tests must be meaningful. Do not write tests that are guaranteed to pass regardless of the code (e.g., asserting `true === true`, testing constants, or wrapping code in try/catch and passing on any result). Every test must be capable of failing — if a test cannot catch a real bug, it has no place in the suite.

## General

- Add brief comments in code explaining *why* things work, not just what they do.
- Prefer teaching moments — flag things the user could try fixing themselves when appropriate.
