# Public About / Privacy / Terms pages

Smartfire serves three public pages for OAuth verification and workspace
visitors: `/about`, `/privacy`, and `/terms`. They render without sign-in,
without setting cookies, without the modern-browser gate, and without any
Google OAuth configuration. They are server-rendered static HTML that works
without JavaScript and disclose no account, member, or room data.

## Status: draft for operator legal review

The privacy and terms texts are **drafts** written for Google's External-app
review and for workspace members (including contractors). They have not been
reviewed by a lawyer. Each hosting organization must review them, supply its
own operator identity (below), and adapt retention and workplace-policy
wording before public rollout and Google verification.

## Configuration

`PublicPolicy` (`app/models/public_policy.rb`) reads the operator identity
from the environment. There are no company defaults.

| Variable | Purpose |
| --- | --- |
| `LEGAL_OPERATOR_NAME` | Hosting organization's public name, shown on all three pages when set. |
| `LEGAL_CONTACT_EMAIL` | Privacy/terms contact address, rendered as a mailto link when set and valid. |
| `LEGAL_EFFECTIVE_DATE` | Optional "Last updated" text (plain words, digits, spaces, commas, hyphens, max 40 chars). Defaults to `September 18, 2026`. |

When unset (or when the email fails validation), the pages use honest
generic wording ("the organization hosting this workspace",
"your workspace administrator") and show no mailto link. Environment
variable names never appear in page text. Values are HTML-escaped on
render, and the email validator rejects whitespace, quotes, angle
brackets, commas, and semicolons. Rails `mail_to` encodes the address for
the URI and escapes its displayed text.

## Framing: self-hosted software, not a central service

Smartfire is open-source, self-hosted software (MIT license, root
`MIT-LICENSE`, verified in the repository; these pages change no license
terms). Each workspace's hosting organization controls that workspace's
data:

- Messages, including direct messages, and uploaded files are stored on
  the workspace's server, may remain in backups, and can be accessible to
  the people operating that server. Content does not vanish automatically
  when a member or contractor leaves.
- Ordinary members are still constrained by room permissions, but that is
  role-based access, not end-to-end encryption and not a privacy guarantee
  against infrastructure operators. The application's administrator role
  alone does not grant access to other people's private rooms or DMs.
- Project maintainers do not automatically receive workspace content from
  self-hosting. Only explicitly configured diagnostics (Sentry via
  `SENTRY_DSN`) or member-authorized integrations send selected data to
  configured services, as disclosed on the pages. Sentry error reports may
  include selected message fields even with default PII collection disabled.
- Content rights do not transfer to the software maintainers. Employment
  or contractor agreements with the hosting organization may govern who
  owns work-related content; the drafts promise no employee ownership.
- Privacy/access/deletion requests go to the workspace operator, not the
  software maintainers. No retention duration or deletion timeframe is
  promised; the operator's own practices apply.

The terms draft therefore covers the MIT software license, authorized
workspace use, sharing responsibilities (including Google permissions the
member grants), acceptable use, third-party terms, and operator actions.
It deliberately contains no forced arbitration, paid plans, indemnity,
venue/law, fixed liability figures, age policy, or IP assignment, and it
preserves nonwaivable rights. It claims neither Google's approval nor
legal enforceability.

## Google-specific disclosures

The privacy page documents, in plain language corroborated against
`docs/google-sign-in.md`, `docs/google-calendar.md`, `docs/google-drive.md`,
`app/models/google/*`, and `app/controllers/google/connections_controller.rb`:

- Sign-in requests only `openid email profile`; the server keeps the
  stable subject, verified email/domain, and name for onboarding, and
  persists no sign-in access/refresh tokens.
- Calendar connection is opt-in, stores encrypted tokens plus connection
  email/scopes, publishes one-way private copies of Going/Maybe events to
  the primary calendar, never reads calendar contents, and cleans up
  best-effort on disconnect (sign-in identity is separate and retained).
- Drive metadata previews resolve at view time with the viewer's
  credentials with a short per-viewer cache; attachments store file IDs
  only. The picker-based sharing flow uses per-file `drive.file` consent
  with a short-lived browser-memory token, grants reader access only to
  explicitly chosen current room members, and persists grants as stated in
  the dialog.
- File contents are never downloaded or stored by the Drive integrations;
  direct uploads are a separate workspace-server feature.
- A Limited Use commitment paraphrased from (not copied from) Google's
  [API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
  which the page links: Google user data serves only the visible features,
  security, and legal compliance; no sale, ads, credit/lending use, or
  generalized AI training. Bots and agents receive only file IDs/links
  under existing room access, never credentials or contents.

## Implementation notes

- `PublicPagesController` inherits from `ActionController::Base`, not
  `ApplicationController`, so the modern-browser gate, the sign-in
  redirect, and all private-state concerns never run. Framework security
  defaults (default response headers, forgery protection, production
  `force_ssl`) still apply. Non-HTML formats answer 404, so no JSON or
  private data is reachable; HEAD works; pages carry no `noindex`.
- `app/views/layouts/public.html.erb` is a minimal standalone layout: no
  importmap/JS, no Turbo/Action Cable/PWA/private meta tags, no
  `Current` references, and no CSRF meta tags (emitting one would create a
  session cookie). Zoom stays enabled. Analytics and Google scripts are
  absent.
- `app/assets/stylesheets/public.css` is self-contained and scoped under
  `body.public`, so the app's `:all` bundle gains no global side effects.
  Light/dark follows `prefers-color-scheme`; keyboard focus is visible;
  `prefers-reduced-motion` disables transitions.
- The sign-in page links About/Privacy/Terms below the panel, beside the
  Google button when configured. No acceptance checkbox or new sign-in
  gate was added.
