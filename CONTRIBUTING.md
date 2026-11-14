# Contributing to VanishCam

Thanks for helping. Small, focused PRs get merged fastest.

## Before you start
- Check [open issues](../../issues). Comment on the one you want so work isn't duplicated.
- New idea? Open an issue first (use the *Feature request* or *New effect mode* template) and wait for a thumbs-up before building something large.
- Security problem? Don't open an issue: see [SECURITY.md](SECURITY.md).

## Setup
Requirements: macOS 14+, Xcode command line tools (Swift 5.9+), [OBS Studio](https://obsproject.com) with its Virtual Camera started once.

```sh
git clone https://github.com/crsthn-slv/VanishCam.git
cd VanishCam
swift build
swift test -c release
scripts/make_app.sh   # build and open the app
```

## Workflow
1. Fork (or branch, if you have access) from `main`.
2. Branch name: `feat/<slug>`, `fix/<slug>`, `chore/<slug>`, `docs/<slug>`.
3. Commit with [conventional-style](https://www.conventionalcommits.org) messages: `feat: add portal mode`.
4. Open a PR against `main`; link the issue with `Closes #N`. Fill in the template.
5. CI must pass. Review comments are resolved by pushing new commits; the PR is squash-merged.

`main` is protected: no direct pushes, PRs only.

## What a good PR has
- One thing per PR, with a clear description of what and why.
- Tests for non-trivial logic. Visual/camera changes: a screenshot or short clip, and what you tried manually (chip, macOS version, call app).
- No new dependencies unless agreed in the issue.
- No assets you don't have the rights to. Sounds and images must be original or under a compatible license (state it in the PR).
- README updated when behaviour or the gesture table changes.

## Code style
Follow the surrounding code. Keep it simple: standard library and system frameworks first, no abstractions for one use, small files. See [AGENTS.md](AGENTS.md) for the conventions in detail.

## AI-assisted contributions
Welcome, with the same bar as any PR: you understand and have run the change, the diff is small, and the PR text is yours. Agents should follow [AGENTS.md](AGENTS.md).

## Reviews
PRs are reviewed by a maintainer, optionally with an AI first pass guided by [REVIEW.md](REVIEW.md). Findings are suggestions; a maintainer decides.

## License
By contributing you agree your work is released under the [MIT License](LICENSE).
