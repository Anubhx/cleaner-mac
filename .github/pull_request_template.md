## Summary

Describe what changed and why.

## Module Scope
- [ ] `CleanerCore` (pure domain / safety rules)
- [ ] `CleanerSystem` (scanning / hashing / deletion / history)
- [ ] `CleanerPreview` (file preview providers)
- [ ] `CleanerUI` (design system / SwiftUI views / workspace store)
- [ ] Documentation / Templates

## Verification Checklist
- [ ] Followed TDD (`RED` -> `GREEN` -> `REFACTOR`) with tests added or updated
- [ ] `./scripts/run-tests.sh` passes with zero warnings
- [ ] `swift build` passes cleanly
- [ ] Zero emoji introduced in UI strings or icons (SF Symbols only)
- [ ] Zero network / telemetry calls added
- [ ] Docs updated if scan rules, safety policy, or UI behavior changed
