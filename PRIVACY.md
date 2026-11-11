# AgentTerm Privacy Policy

_Effective date: November 11, 2026_

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

**The developer does not receive, collect or store any of your data.** AgentTerm has no server of its
own, no account, no analytics and no advertising. What you type, what your terminals show, your files
and your conversations with coding agents stay on your own devices. The Mac app is open source, so
this can be checked.

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

None through the Software. If you install the iPhone app from TestFlight or the App Store, Apple may
share crash reports and usage statistics with the developer if you have agreed to that in your
device's settings. If you write to the support address, your message and email address are used only
to answer you.

## 7. Children

The Software is a developer tool and is not directed at children.

## 8. Changes

Changes to this policy are published on this page with a new effective date.

## 9. Contact

Questions about this policy: manhpv151090@gmail.com
