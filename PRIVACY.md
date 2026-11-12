# AgentTerm Privacy Policy

_Effective date: November 12, 2026_

## 1. Introduction

This Privacy Policy describes how **AgentTerm** ("the app") handles information when you use the
AgentTerm app for macOS and the AgentTerm app for iPhone (together, "the Software").

AgentTerm is a terminal for AI coding agents. The Mac app runs terminal sessions on your Mac. The
iPhone app is a remote control for those sessions.

The Software is developed and published by an individual developer:

- **Developer:** Manh Pham
- **Contact:** manhpv151090@gmail.com
- **Project page:** https://github.com/manhpham90vn/AgentTerm

## 2. The short version

**What you type, what your terminals show, your files, your folders and your conversations with
coding agents stay on your own devices.** AgentTerm has no server of its own, no account and no
advertising.

The released apps can send two things to the developer through Google's Firebase, and you control
both:

- **Crash reports**, only if you say yes when the app asks at its first launch.
- **Usage statistics**, counts of which features are used. On by default; one switch turns it off.

Neither ever contains what a terminal showed, a prompt, a file name or a folder. Section 6 lists
exactly what is sent. Both apps are open source, so this can be checked, and an app you build from
the source yourself sends nothing at all.

## 3. What stays on your devices

- **Terminal sessions.** Their input and output are kept in memory by the AgentTerm host on your Mac
  while a session runs. They are not written to disk by AgentTerm and are not sent to the developer.
- **Your project files and git repositories.** AgentTerm reads and changes them only on your Mac, when
  you browse, edit, stage or commit from the app.
- **Conversation history.** The History tab reads the files that Claude Code, Codex, Antigravity and
  Copilot CLI already keep on your Mac. AgentTerm does not copy them elsewhere. A handoff writes a
  summary file into the project folder, under `.agentterm/handoffs/`.
- **Pairing.** A paired iPhone holds a token in its Keychain. The Mac holds only a hash of it, in
  `~/Library/Application Support/AgentTerm`. You can remove a paired device in the Mac app at any time.
- **Settings.** Your folder list and preferences are stored on the device they belong to.

## 4. Connections the Software makes

- **Between your iPhone and your Mac.** The iPhone app connects only to the Mac you paired it with,
  over your local network or your own Tailscale network. The developer is not part of that
  connection. Tailscale is a separate service with its own privacy policy.
- **To the services of the coding agents you use.** To show what your account has left (the figures
  the agents show under `/usage` or `/status`), the Mac app asks the agent's own service: Anthropic,
  OpenAI (ChatGPT), Google or GitHub. For this it reads the sign-in that the agent keeps on your Mac
  and sends it only to the service that issued it. It is not stored, logged, sent to the iPhone or
  sent to the developer. Starting the host with `agenttermd --no-account-usage` turns this off.
- **The agents themselves.** Claude Code, Codex, Antigravity and Copilot CLI are separate programs
  that you install and sign in to. What they send to their providers is governed by those providers'
  policies, not by this one.

## 5. Permissions on iPhone

- **Camera:** used only to scan the pairing QR code that the Mac app shows. No image is stored or sent.
- **Local network:** used to reach the AgentTerm host on your Mac.

## 6. Data the developer receives

The apps released by the developer (the disk image, the Homebrew cask, TestFlight and the App Store)
include Google's Firebase. Google processes the data below on the developer's behalf; see
[Firebase's privacy information](https://firebase.google.com/support/privacy).

**Usage statistics (Firebase Analytics).** On unless you switch it off.

- The events, and all of them: the app was opened; a session was started, and with which agent
  (Claude Code, Codex, Antigravity, Copilot CLI or a shell); a phone was paired; a conversation was
  handed off, from which agent to which, and whether to another folder (yes or no); the Mac and the
  iPhone were of different versions.
- What Firebase records by itself once usage statistics are on: the first time the app is opened on
  a device, each time a period of use begins, and how long the app was in the foreground.
- What Firebase adds to every event: the app's version, your device's model and system version, your
  language and country, and an identifier that Firebase makes for this installation of the app. It is
  not tied to your name or account, and the advertising identifier is not used.
- Never: anything you type, anything a terminal shows, prompts, file names, folder names, the names
  of your Macs, or anything from the sign-ins of the coding agents. An event has no field that could
  hold such text.

**Crash reports (Firebase Crashlytics).** Off until you say yes.

- When the app crashes: where in the app's code it happened, the app's version, your device's model
  and system version, and the installation identifier.
- When the host on the Mac stops unexpectedly: only the fact that it did.

**Your choices.** The app asks about crash reports once, the first time it is opened. Both switches
are in **Settings > Privacy** on the Mac and under **Privacy** in the menu of the iPhone app, and a
change takes effect at once.

**Builds that send nothing.** An app built from the source code, and the development build
"AgentTerm Dev", contain no Firebase configuration and send nothing, whatever the switches say.

**Other.** If you install the iPhone app from TestFlight or the App Store, Apple may share crash
reports and usage statistics with the developer if you have agreed to that in your device's
settings. If you write to the support address, your message and email address are used only to
answer you.

## 7. Children

The Software is a developer tool and is not directed at children.

## 8. Changes

Changes to this policy are published on this page with a new effective date.

## 9. Contact

Questions about this policy: manhpv151090@gmail.com
