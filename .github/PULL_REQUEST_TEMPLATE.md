## What this changes

<!-- One or two sentences. Link the issue if there is one: Fixes #123 -->

## Why

<!-- The problem being solved, not a restatement of the diff. -->

## How it was verified

<!-- Be specific and honest. "Tested against a real Wasabi bucket" is worth
     more than a ticked box. Say what you could NOT verify — untested paths
     are fine to merge when they're declared. -->

- [ ] `swift build -c release` with no warnings
- [ ] `swift run openborld-tests` green
- [ ] `bash Scripts/check-portability.sh` passes
- [ ] Tested against a real service (which one? ______)
- [ ] Added a test covering the change

## Checklist

- [ ] Commits are signed off (`git commit -s`) — see CONTRIBUTING.md
- [ ] No secrets, tokens, or account names in the diff
- [ ] No new third-party dependency (or it was discussed in an issue first)
- [ ] UI changes use design tokens, name every icon-only control, and don't
      rely on colour alone
