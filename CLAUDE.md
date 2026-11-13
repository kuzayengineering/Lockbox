# Lockbox – working rules

## Builds: held by default
Every push to `main` normally triggers the GitHub Actions build and a new
release (which uses Actions minutes). The owner has asked to **hold builds
by default**:

- Commit and push every change as usual (so work is safe on GitHub), but
  put `[skip ci]` in the commit message so no build runs.
- Only when the owner says to build (e.g. "build it", "make a release"),
  push without `[skip ci]` (or start Actions > Build > Run workflow). One
  build then includes everything pushed since the last one.
- Windows is built only when asked: add `[windows]` to that commit message.
  Never write the literal text `[windows]` or `[skip ci]` in a commit
  message unless that effect is intended.
