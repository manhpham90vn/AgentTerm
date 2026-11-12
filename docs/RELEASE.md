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

The version of both apps is the one line of the `VERSION` file at the root
of the repository; `make bump V=0.3.0` changes it. `VERSION=0.3.0-beta.1` in
front of a command builds another one without changing the file. When the
protocol version changes with it, add a row to the compatibility table in
the README.

## Released builds and development builds

A build made on your own machine is not the released app. `scripts/run-mac.sh`
and a Debug build of the iPhone project produce **AgentTerm Dev**, an app of
its own that can be installed next to the released one:

| | Released | Development |
|---|---|---|
| Name | AgentTerm | AgentTerm Dev |
| Bundle identifier | `com.manhpham.agentterm` | `com.manhpham.agentterm.dev` |
| Data on the Mac | `~/Library/Application Support/AgentTerm` | `~/Library/Application Support/AgentTerm Dev` |
| Host port | 7717 | 7718 |
| Pairing links | `agentterm://` | `agentterm-dev://` |

So trying a change never touches the installed app's sessions or paired
devices. Either app understands the other's pairing links. The release lanes
build the released app (`CHANNEL=release` for the Mac, the Release
configuration for the iPhone); nothing else does.

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
timestamp, and puts the app in `dist/AgentTerm-<version>.dmg`, next to a
shortcut to Applications to drag it onto. The
certificate is imported into a keychain of its own for the run and that
keychain is deleted afterwards.

`mac release` then sends the disk image to Apple's notary service, waits
for the verdict, staples the ticket to it and checks it with `spctl`.

The app is built for the Mac it is built on (Apple silicon on an Apple
silicon Mac). There is no universal build yet.

## Before a release

- `VERSION` holds the version being released. A release as `0.3.0-beta.1`
  is a pre-release of `0.3.0`; the workflow refuses a version that is not
  the one in the file (`scripts/check-version.sh`).
- `packaging/release-notes/v<version>.md` says what changed, one file for a
  version and its pre-releases. The workflow refuses to release without it
  (`scripts/check-release-notes.sh`). The GitHub release shows it, and
  TestFlight gets it as "What to Test", for which the iPhone lane waits until
  Apple has processed the build. `NOTES=0` skips the waiting and the notes.

`make release V=0.3.0-beta.1` runs both checks and then starts the workflow.

## Homebrew

The Mac app also installs with

```sh
brew tap manhpham90vn/tap
brew trust manhpham90vn/tap     # Homebrew 7 and later: a tap outside Homebrew's own has to be trusted first
brew install --cask agentterm
```

The cask lives in the tap repository, `manhpham90vn/homebrew-tap`, and is
written from the template `packaging/homebrew/agentterm.rb`.
`scripts/publish-homebrew.sh <version>` fills in the version and the checksum
of that version's disk image and pushes it to the tap. The release workflow
runs it after publishing the disk image, when the `HOMEBREW_TAP_TOKEN` secret
is set. By hand it uses git's sign-in on your machine; `DRY_RUN=1` prints the
cask and pushes nothing. Beta versions are published to the tap too.

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
