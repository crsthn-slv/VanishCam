# Debt / backlog
- UYVYConverter allocates an MTLBuffer per frame; reuse a ring buffer.
- Substitution/Teleport overlays assume a bottom-of-frame person; mask-derived y-centre would be more robust.
- Call detection reads the OBS extension's "stop streaming" log line (`log stream`); breaks if OBS/macOS change that message.
- No bundled poof sound (not redistributable). Substitution runs silent without it.
- Translations: UI strings are LocalizedStringKey literals; add Localizable.xcstrings and copy *.lproj in make_app.sh.
