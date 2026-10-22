# Security Policy

## Supported versions

Only the latest release gets fixes. Lime updates itself through Sparkle, and each update is signed with an EdDSA key, so most people move to a new version within a day.

| Version | Supported |
| ------- | --------- |
| Latest 1.x release | ✅ |
| Older releases | ❌ |

## Reporting a vulnerability

Please **don't open a public issue**. Use the private form instead:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe the problem, the Lime and macOS versions, and the steps to reproduce it.

Only the maintainer can see the report. You'll usually get a reply within a week, and you'll be credited in the release notes unless you'd rather not be.

## Worth knowing

- Lime isn't notarized by Apple yet; the README explains how to open it.
- Lime makes no network requests while converting or editing files. Its only connection is Sparkle's daily check of the appcast on GitHub.
- The bundled ffmpeg is built with networking turned off (`--disable-network`).
