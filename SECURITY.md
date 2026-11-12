# AgentTerm Security Policy

## Reporting a problem

Please do not open a public issue for a security problem. Report it privately
with **Report a vulnerability** on the repository's
[Security tab](https://github.com/manhpham90vn/AgentTerm/security), or by
email to the address in [SUPPORT.md](SUPPORT.md). Say which version of
AgentTerm, on which macOS and iOS, and how to reproduce it.

Fixes go into the newest release. Older versions are not patched.

## Read this first

AgentTerm's host gives whoever connects a shell on your Mac, as you. Reach it
from the Mac itself or over [Tailscale](https://tailscale.com). **Do not
forward its port to the internet or to a network you do not control.**

## What AgentTerm does to protect you

| | |
|---|---|
| Who can reach the host | It listens on `127.0.0.1` and on the Mac's Tailscale address only, never on the local network or any other interface. |
| Who can connect | Every connection needs a token. Unauthenticated connections are closed after 10 seconds, and tokens and codes are compared in constant time. |
| Pairing an iPhone | The Mac shows a code that works once, for five minutes, and only while the pairing screen is open. The phone trades it for a token of its own. |
| Taking a device off | Each paired device has its own token, which the Mac can revoke under **Pair iPhone**. |
| The Mac's own token | It is kept in a file only you can read (mode 0600) and is accepted only on connections that arrive on the loopback interface, so it is no use from another machine. |
| Your data | Nothing reaches the developer. AgentTerm has no server of its own, no account and no analytics. See [PRIVACY.md](PRIVACY.md). |
| Files you preview | A Markdown preview runs nothing from the file: HTML in it is turned into Markdown, and scripts and styles are not interpreted. |

## What it does not protect against

- **Anyone with a valid token has your shell.** A paired phone that is lost
  or unlocked by someone else can run anything you can, until you revoke it
  on the Mac.
- **The WebSocket is not encrypted by AgentTerm.** Traffic on the Mac stays on
  the loopback interface, and traffic to the phone is encrypted by Tailscale
  (WireGuard). On any other path it would be readable, which is why the host
  listens nowhere else.
- **Other devices in your tailnet can reach the port.** They still need a
  token, but the port is visible to them, and to nodes shared into the
  tailnet.
- **Agents act with your permissions.** AgentTerm starts the agent CLIs you
  have installed; what they do in a session, and the macOS permissions you
  grant AgentTerm on their behalf, are theirs to use.
- **Account usage reads the agents' sign-ins.** To show what your account has
  left, AgentTerm reads each agent's sign-in on your Mac and sends it only to
  the service that issued it. `agenttermd --no-account-usage` turns this off.
- **No protection against flooding** of the port by something already on the
  tailnet.

The design behind this is in [docs/DESIGN.md](docs/DESIGN.md).
