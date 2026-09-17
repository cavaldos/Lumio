## Summary

-

## Why

## Changes

-

## Testing

- `core`
  - [ ] `cargo check --workspace --manifest-path core/Cargo.toml`
  - [ ] `cargo test --workspace --manifest-path core/Cargo.toml`

- `bridge/ffi`
  - [ ] `cargo check --manifest-path bridge/ffi/Cargo.toml`
  - [ ] `cargo test --manifest-path bridge/ffi/Cargo.toml`

- `apps/macos`
  - [ ] macOS app (if `apps/macos/**` touched): `xcodebuild -project "apps/macos/LauncherApp/look-app.xcodeproj" -scheme "Look" -configuration Debug -sdk macosx build`
  - [ ] Manual verification completed (if UI/behavior changed)

## Screenshots / Recordings (if UI changed)

### Before

### After

## Risks / Notes

-

## Checklist

- [ ] I have read and agree to the CLA (CLA.md)
- [ ] PR title is clear and scoped
- [ ] Docs updated for user-visible changes
- [ ] No secrets or private files included
- [ ] Backward compatibility considered
