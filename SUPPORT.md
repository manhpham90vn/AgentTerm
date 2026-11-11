# AgentTerm Support

Need help? Email [manhpv151090@gmail.com](mailto:manhpv151090@gmail.com?subject=AgentTerm%20Support),
or open an issue at [github.com/manhpham90vn/AgentTerm](https://github.com/manhpham90vn/AgentTerm/issues).
Please include your macOS and iOS versions, the AgentTerm version, which agent you were using and the
steps that led to the problem.

## Frequently asked questions

### What do I need?

A Mac with macOS 14 or later for the Mac app, and at least one coding agent installed: Claude Code,
Codex, Antigravity or Copilot CLI. AgentTerm only shows the launch buttons of the agents it finds. For
the iPhone app you need iOS 17 or later, and Tailscale on both the Mac and the iPhone, signed in to
the same account.

### How do I pair my iPhone?

In the Mac app click **Pair iPhone**. Open AgentTerm on the iPhone and scan the QR code, or copy the
pairing link from the Mac and paste it into the iPhone app. A code works once and for five minutes,
and stops working when the pairing window closes.

### The Mac shows instructions instead of a QR code

Tailscale is not installed, not signed in or not connected on the Mac. Follow the steps shown; the
code appears by itself once Tailscale is ready.

### The iPhone cannot connect

Check that Tailscale is connected on both devices and signed in to the same account, and that
AgentTerm is running on the Mac (it may be in the menu bar). If the Mac removed the iPhone from its
paired devices, pair it again.

### Why is the terminal on my Mac small and framed?

The session is being driven from the iPhone, so it has the phone's size. Click **Use This Window's
Size** on the Mac, or type in the session, to take it back.

### Do sessions keep running when I close the window?

Yes. They are held by a host program on the Mac, separate from the window. By default AgentTerm also
stays in the menu bar when its window is closed; this can be turned off in Settings.

### Where do the usage figures come from?

From the agent's own service, asked with the sign-in the agent keeps on your Mac. See the
[privacy policy](https://manhdev.click/projects/agentterm/privacy) for exactly what is sent where,
and how to turn it off.

### How do I remove AgentTerm?

Quit the app from its menu bar icon and move it to the Trash. Its data is in
`~/Library/Application Support/AgentTerm`. On the iPhone, delete the app.
