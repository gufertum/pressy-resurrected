# CLAUDE.md

macOS daemon plus menu bar app (Swift 6, SwiftPM, only dependency Yams) that seizes the jack's built-in `Headset` HID device and maps
Pressy press patterns to actions. User docs: README.md.

## Commands

- `make test` - swift test (adds the swift-testing plugin path needed with Command Line Tools only)
- `make build` - release build, `.build/release/pressy`
- `make install` / `make uninstall` - binary to ~/.local/bin, LaunchAgent `li.sudo.pressy`
- `make cert` - one-time self-signed identity "pressy local signing"; install.sh signs with it so TCC grants survive rebuilds (ad-hoc otherwise)
- `.build/release/pressy trigger <pattern> --config <file>` - run one action without the button

## Layout

- `Sources/PressyCore` - pure, unit-tested logic: `PatternRecognizer`, `Config` (YAML or JSON by extension, strict; default ~/.config/pressy/config.yaml), `AudioRoutePolicy`, `BuiltinAction`
- `Sources/pressy` - IOKit HID (`HeadsetButton`), CoreAudio (`AudioHardware`, `AudioRouteGuard`), `ActionRunner`, CLI in `main.swift`
- `Support/Info.plist` - embedded into the binary via `-sectcreate` (bundle id for TCC)
- `scripts/` - install / uninstall, LaunchAgent plist is generated there

## Hardware facts (MacBook Pro M5, macOS 27)

- Press = HID usage 0x0C/0xCD on `Transport=Audio, Product=Headset` (`AppleCS42L84Mikey`), value 1/0, no auto-repeat.
- Use ONE matching dictionary: a device matching several is delivered once per match.
- Seize works as a normal user and suppresses the system Play/Pause key; a second seize returns 0xE00002C5.
- Plug-in creates new CoreAudio devices each time: output source `hdpn`, input source `emic` (~2.5 s later).
- MediaRemote answers nothing to third-party processes; media keys are posted as NX_SYSDEFINED events instead.

## Task tracking

Tasks live in Forgejo issues, not in files: do not create TODO.md or TODO_DONE.md.
Open issue = TODO, label `status/wip` = in progress, label `status/human` = waiting for a human
(assigned to that human), assigned to `claude` = ready for Claude, closed issue = done. Use the `forgejo-issues` skill (`fji status`, `fji new`, `fji start`,
`fji done`). Branches are `feature/<issue>-<slug>`, commit subjects start with `#<issue>`.
`SECRETS.md` holds the local report of the `secrets-scan` skill: excluded from git, redacted, never commit it.
