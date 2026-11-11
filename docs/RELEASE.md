# Releasing AgentTerm

Two things are released: the iPhone app, through TestFlight, and the Mac
app, as a notarized disk image to download. The Mac app cannot go on the
Mac App Store: it starts shells and other programs, which the App Sandbox
the store requires does not allow.

Both run through `scripts/release.sh`, which reads the secrets from the
private dotfiles repo and hands them to fastlane. Nothing secret is kept
here.

```sh
scripts/release.sh --check        # which secrets and tools were found
scripts/release.sh ios build      # build the iPhone app signed for the App Store
scripts/release.sh ios beta       # ... and upload it to TestFlight
scripts/release.sh mac sign       # build AgentTerm.app, sign with Developer ID, make a .dmg
scripts/release.sh mac release    # ... and notarize it
```

`VERSION=0.2.0` in front of a command sets the version. Otherwise it is
`APP_VERSION` of the project's `release.env`, or the one in
`iOS/project.yml`.

## What it needs

- Xcode, `brew install fastlane xcodegen`.
- In the dotfiles repo, `projects/agentterm/release.env` naming the Apple
  account, and under `accounts/apple/<TEAM_ID>/`:
  - `apple.env` with `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`,
    `MATCH_GIT_URL`, `MATCH_PASSWORD`, and `DEVELOPER_ID_P12_PASSWORD` if the
    certificate has one;
  - `AuthKey_<KEYID>.p8`, the App Store Connect API key;
  - `certs/developer_id_application.p12`, the Developer ID certificate.

## iPhone

The bundle identifier is `com.manhpham.agentterm`. Before the first upload:

1. The identifier is registered in Certificates, Identifiers & Profiles.
2. The app exists in App Store Connect with that identifier. fastlane cannot
   create it with an API key; it is made by hand, once.
3. match holds an App Store provisioning profile for it. The first time,
   `scripts/release.sh ios build create:true` lets match make it and store
   it in the match repository. After that the lanes only read it.

`ios beta` gives the build the next number after the newest one TestFlight
has for the version, and does not wait for Apple to finish processing it.

## Mac

`mac sign` builds a release `AgentTerm.app`, signs the daemon and then the
app with the Developer ID certificate, with the hardened runtime and a
timestamp, and puts the app in `dist/AgentTerm-<version>.dmg`. The
certificate is imported into a keychain of its own for the run and that
keychain is deleted afterwards.

`mac release` then sends the disk image to Apple's notary service, waits
for the verdict, staples the ticket to it and checks it with `spctl`.

The app is built for the Mac it is built on (Apple silicon on an Apple
silicon Mac). There is no universal build yet.

## From GitHub Actions

`.github/workflows/release.yml` runs the same lanes on GitHub's runners.
Pushing a tag such as `v0.2.0` releases both apps: the Mac disk image goes
on a GitHub release of that tag with its checksum, the iPhone app goes to
TestFlight. A version with a suffix (`v0.2.0-beta.1`) makes the GitHub
release a prerelease. The workflow can also be run by hand with a version,
for one of the two apps or both.

Its secrets are set from the dotfiles repo, which shows what it would set
before setting anything:

```sh
scripts/sync-agentterm.sh            # in the dotfiles repo: dry run
scripts/sync-agentterm.sh --apply
```

`.github/workflows/ci.yml` builds the package and runs its tests on every
push and pull request.
