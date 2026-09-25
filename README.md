# Agent Allowance

A small native macOS menu-bar app that shows the allowance remaining for Codex, Claude, Cursor, Devin, Grok Build, Grok Bot, and Antigravity (`agy`). It reports both the percentage remaining and the time until each available limit resets.

<img src="assets/example.png" alt="The Agent Allowance popover listing remaining allowance and reset time for each provider" width="456">

## What's New

### 2026-09-25

- **Allowance notifications.** Get an alert when an allowance that ran out resets, or when one drops to a threshold you choose (5–20%). Alerts go to macOS Notification Center, to your iPhone through Pushover, Simplepush or ntfy, or both. Open Settings with the gear icon in the popover. See [Push Notifications](#push-notifications).
- **Background checks** every 2–15 minutes while any notification channel is on, so alerts arrive without opening the popover. An alert that fails to send is retried, but only on the channels that missed it.
- **Push keys in the Keychain.** Pushover and Simplepush keys are stored in the macOS Keychain, never in the preferences file.
- **App icon** in the bundle, shown in Mac notifications.
- **Settings opens in front.** The popover now closes when you click the gear.
- **Stable signing for local builds.** `package_app.sh` signs with an Apple Development or self-signed certificate when one is available, so macOS stops asking for Keychain access after every rebuild. See [Code signing and Keychain prompts](#code-signing-and-keychain-prompts).

### 2026-09-01

- **First public release.** Allowance remaining and time to reset for Codex, Claude, Cursor, Devin, Grok Build, Grok Bot and Antigravity. Agents you have not installed are hidden.
- **Claude weekly allowance fix.** After a change to Claude's usage endpoint, the weekly allowance could read 0% remaining at low usage; it now reads correctly. Plans with a model-specific weekly pool show it as its own row.

## What it reads

- **Codex:** the authenticated local Codex app-server rate-limit method.
- **Claude:** the Claude Code OAuth usage endpoint and the existing Claude Code credential.
- **Cursor:** its current billing-cycle usage endpoint, using Cursor's existing local sign-in and device identity.
- **Devin:** the current daily, weekly, or billing-cycle allowance stored in Devin's local signed-in status. Expired cached windows are omitted until Devin refreshes them.
- **Grok Build:** the Grok CLI billing endpoint and the existing Grok CLI credential. Only its reported weekly pool is displayed.
- **Grok Bot:** its separate SuperGrok usage pool, using Grok Bot's existing local Keychain-backed sign-in.
- **Antigravity:** `agy -p "/usage"`, which reports separate Gemini and Claude/GPT pools.

The app does not submit model prompts. Provider credentials are read only when refreshing and are never stored by Agent Allowance.

## Requirements

- macOS 14 or newer
- Swift 6 / Xcode Command Line Tools
- At least one supported agent installed and signed in

You do not need all seven. **Agents you have not installed are hidden**, so the
popover only lists what you actually use. An agent that is installed but signed
out is still listed, with a line telling you how to sign in — those are the
errors worth acting on. If no agent is found at all, the popover says so.

## Setting up each provider

Each provider reuses the sign-in that its own tool already stores. Agent
Allowance never asks for provider credentials and never stores them.

| Provider | Install | Sign in | Allowance shown |
|---|---|---|---|
| **Codex** | `codex` CLI | `codex login` | 5-hour session and weekly |
| **Claude** | `claude` CLI (Claude Code) | `claude login` | 5-hour session and weekly, per model where the plan has one |
| **Cursor** | Cursor desktop app | Sign in inside Cursor | Current billing cycle |
| **Devin** | Devin desktop app | Sign in inside Devin | Daily, weekly, or billing cycle |
| **Grok Build** | `grok` CLI | `grok login` | Weekly |
| **Grok Bot** | Grok Bot desktop app | Sign in inside Grok Bot | Weekly SuperGrok pool |
| **Antigravity** | `agy` CLI | Sign in inside `agy` | Gemini and Claude/GPT pools |

Provider-specific notes:

- **Claude** reads the first credential it finds: the `CLAUDE_CODE_OAUTH_TOKEN`
  environment variable, then `~/.claude/.credentials.json`, then the
  `Claude Code-credentials` Keychain item. A normal Claude Code sign-in is
  enough — the environment variable is only useful when running from a shell,
  since an app launched from Finder inherits no shell environment.
- **Claude** shows every limit the usage endpoint reports for your plan: the
  5-hour session, the weekly all-models pool, and any model-scoped weekly pool
  (shown as a second `Weekly` row named after the model). Plans with a single
  weekly pool keep one unqualified `Weekly` row.
- **Grok Bot** decrypts its `Grok Bot Safe Storage` Keychain item, so macOS asks
  once whether Agent Allowance may use it. Allow it, or Grok Bot stays blank.
- **Devin** has no live endpoint; it reads the status Devin cached at its last
  sign-in. Windows whose reset time has passed are dropped, so if Devin is
  stale, open it once and refresh.

### If a provider you installed does not appear

Agent Allowance looks for CLIs in `~/.local/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`, `/usr/bin`, and `/bin`, plus whatever is on `PATH`. An app
launched from Finder does not inherit your shell's `PATH`, so a CLI installed
somewhere else — a version manager's shim directory, for example — is treated
as not installed and hidden. Symlink it into one of those directories to make
it visible.

## Build and run

```sh
./scripts/package_app.sh
open build/AgentAllowance.app
```

The packaged app is written to `build/AgentAllowance.app`. It has `LSUIElement` enabled, so it appears only in the menu bar and not in the Dock.

### Code signing and Keychain prompts

Pushover and Simplepush keys are stored in the Keychain, and macOS remembers "Always Allow" for a specific app signature. `package_app.sh` signs with the first of these it finds:

1. `SIGN_IDENTITY`, if you set it (a certificate name or SHA-1 hash).
2. A valid Apple Development certificate in your keychain. Any Apple ID signed in to Xcode can create one: Xcode → Settings → Accounts → Manage Certificates → + → Apple Development.
3. A self-signed certificate named "Agent Allowance Local Signing".
4. Ad-hoc signing.

Options 1–3 give the same signature on every rebuild, so you allow Keychain access once. An ad-hoc signature changes with every build, so macOS asks again after each rebuild.

Without an Apple ID in Xcode, create the self-signed certificate once:

```sh
./scripts/create_signing_identity.sh
```

It creates the certificate in your login keychain; nothing is sent anywhere. To remove it, delete "Agent Allowance Local Signing" in Keychain Access.

## Reading the display

All percentages mean **allowance remaining**:

- Green: 50–100% remaining
- Yellow: 20–49% remaining
- Red: under 20% remaining

Tap the menu-bar gauge to refresh data that is more than a minute old, or use the refresh button for an immediate update.

## Push Notifications

Agent Allowance can alert you when an allowance that ran out resets, or when one runs low. Open Settings with the gear icon in the popover footer and turn on either or both channels:

- **Mac Notifications:** banners in macOS Notification Center. macOS asks for permission the first time; Settings shows whether it was granted.
- **iPhone Notifications:** push notifications through **Pushover**, **Simplepush** or **ntfy**. Pick one with the Push Service control.

### Triggers

- **Reset:** when a 5-hour session, weekly pool or billing cycle that ran out (5% or less remaining) refills. A window that resets before running out does not alert.
- **Low allowance:** when an allowance drops to or below a threshold you choose: 5%, 10%, 15% or 20%.

While any channel is on, the app checks in the background every 2, 5, 10 or 15 minutes (set in Settings), so alerts arrive without opening the popover. An alert that fails to send is retried on the next checks, up to three attempts, and only on the channels that missed it.

Each channel has a test button and a **Test in 10s** button, so you can switch away and confirm that a delayed alert still arrives.

### iPhone setup with Pushover

1. Install **Pushover** on your iPhone and sign in.
2. In Settings, turn on **iPhone Notifications** and choose **Pushover.net**.
3. Enter the **User Key** from your [pushover.net](https://pushover.net) dashboard.
4. Pushover also needs an application token for the app sending the alerts. Use **Create App Token on pushover.net** in Settings, create an application, and paste its **API Token**.
5. Click **Test Pushover**.

### iPhone setup with Simplepush

1. Install **Simplepush** on your iPhone. The app shows your key when it opens.
2. In Settings, turn on **iPhone Notifications** and choose **Simplepush**.
3. Paste the key. Simplepush needs no account or app token.
4. Click **Test Simplepush**.

### iPhone setup with ntfy

1. Install **ntfy** on your iPhone.
2. In Settings, turn on **iPhone Notifications** and choose **ntfy.sh**.
3. Enter a topic name, or click the dice button to generate a random one such as `allowance-a1b2c3d4`. Anyone who knows a topic name on ntfy.sh can read its messages, so use a name that is hard to guess.
4. In the ntfy app, subscribe to the same topic. The copy button in Settings copies the name.
5. Click **Test ntfy**.

To use your own ntfy server, enter its address under **Advanced: Custom Server**.

### Troubleshooting and storage

If macOS notifications show a blank app icon after you build a version with a new icon, Notification Center may still be showing an icon it saved earlier. Running `killall NotificationCenter` (it relaunches right away) and sending a test notification can refresh it.

Pushover and Simplepush keys are stored in the macOS Keychain, not in the app's preferences. If the Keychain refuses a key, Settings shows the error; a newly entered key is kept only in memory until the Keychain accepts it, never written to the preferences file.

## License

Released under the [MIT License](LICENSE).

Agent Allowance is an independent project and is not affiliated with, endorsed
by, or sponsored by any provider it supports. Provider and product names are
trademarks of their respective owners and are used here only to identify the
services whose allowances the app displays. The app relies on local credentials,
local status data, and provider endpoints that may change at any time without
notice, and it is provided as is, without warranty of any kind.
