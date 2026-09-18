# Sign in with Google

Smartfire supports Google sign-in for a configurable list of Workspace
domains. No company domains are built into the application. Email/password
sign-in and invitation registration remain available for other email
addresses. This restriction applies only to Google sign-in.

An existing member signing in with their verified work email keeps their
account, messages, room memberships, role, and password. A new eligible
Workspace user receives an ordinary member account and the usual open-room
memberships. Private rooms still require membership. Google-created accounts
start without a password; they use Google to sign in.

Google login is separate from [Calendar publishing](google-calendar.md) and
[Drive previews](google-drive.md). It requests only `openid email profile`,
does not connect Calendar or Drive, and does not store Google access or
refresh tokens. Disconnecting Calendar does not disconnect Google login.

## Google Cloud setup

For a deployment using Calendar and Drive too, follow the combined
[Google Workspace setup checklist](google-workspace-setup.md).

1. Create or reuse a **Web application** OAuth client in Google Cloud. The
   existing Calendar/Drive client can also serve sign-in.
2. Add the exact authorized redirect URI:
   `<app root URL>/session/google/callback`.
   For the Smart Data deployment, this is
   `https://chat.smartdata.net/session/google/callback`.
   Keep the existing `/google/callback` URI for Calendar/Drive connections.
   For local development, also register
   `http://localhost:3000/session/google/callback` if needed.
3. Configure the Google Auth Platform audience as **External** for Smart
   Data: `smartdata.net` and `cnbssoftware.com` belong to separate Workspace
   organizations. Smartfire still enforces its domain allowlist. An
   **Internal** audience would prevent the other organization from reaching
   sign-in. Review the publishing status and each organization's Workspace
   administrator restrictions before rollout. See Google's
   [audience documentation](https://support.google.com/cloud/answer/15549945).
4. Configure the application host with `GOOGLE_CLIENT_ID` and
   `GOOGLE_CLIENT_SECRET`. Keep the secret in the host's secret configuration,
   never source control.
5. Set `GOOGLE_SIGN_IN_DOMAINS` on the host to a comma-separated list of
   allowed Workspace domains. For Smart Data, use
   `GOOGLE_SIGN_IN_DOMAINS=smartdata.net,cnbssoftware.com`. Other installations
   supply their own domains. A missing or empty value disables Google
   sign-in; it never allows every domain. To add or remove a domain, update
   the host environment and restart the application; no code change is
   required.
6. Deploy the application and run its database migrations through the normal
   release process. The Google button appears when credentials and allowed
   domains are configured.

No Calendar or Drive API access is required for sign-in itself. Those
integrations retain their own configuration and user consent.

## Account identity and access

Google's verified identity is checked on the server before any account is
created or session starts. Smartfire verifies the token's signature, issuer,
audience, expiry, nonce, verified email, and Workspace domain. A domain hint
in the account chooser does not grant access. See Google's
[identity verification guidance](https://developers.google.com/identity/gsi/web/guides/verify-google-id-token).

The initial link matches an existing human account by email without regard
to letter case; ambiguous matches are rejected. Later sign-ins use Google's
stable account identifier, so changing a Google email does not create a new
Smartfire account. A different Google identity cannot take over an existing
link. Administrator roles are never assigned by automatic onboarding.

Deactivated or banned members cannot sign in with Google. Their stored
identity link survives deactivation, preventing automatic recreation of the
same account. Bot and agent identities are not eligible for Google login.

Google sign-in creates a normal Smartfire session. Suspending a Google
account does not immediately revoke a Smartfire session already in use;
administrators should also deactivate the Smartfire member during
offboarding, which removes their sessions.

## Rollout checks

- Sign in with an existing member from each allowed domain and confirm their
  account, role, and history are retained.
- Sign in with a new employee account and confirm ordinary member access.
- Attempt Google sign-in with a different domain and confirm the page offers
  email/password sign-in. Verify an existing external member can still sign
  in with their password.
- Cancel Google's consent flow and confirm returning to the sign-in page is
  recoverable. Check that Calendar/Drive connection settings are unchanged.

If Google reports `redirect_uri_mismatch`, correct the authorized redirect
URI to match the application's public scheme, host, and callback path
exactly. If it reports `org_internal`, check whether both domains belong to
the same Workspace organization as the OAuth project. If the Google button
is absent, check credential presence and the domain configuration.
