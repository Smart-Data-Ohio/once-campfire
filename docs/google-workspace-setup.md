# Google Workspace deployment setup

This checklist covers [Google sign-in](google-sign-in.md),
[Calendar publishing](google-calendar.md), and [Drive sharing](google-drive.md).
Enabling the APIs does not configure OAuth or connect individual members.

## Google Cloud project

Use the same project for the OAuth web client, Calendar, Drive, and Picker.
For Smart Data, the project is `smart-data-campfire` (number `677278000060`).
Always specify the project explicitly; the operator's default may differ.

```sh
gcloud services enable \
  calendar-json.googleapis.com drive.googleapis.com picker.googleapis.com \
  --project=smart-data-campfire

gcloud services list --enabled --project=smart-data-campfire \
  --filter='config.name:(calendar-json.googleapis.com drive.googleapis.com picker.googleapis.com)' \
  --format='table(config.name,config.title)'
```

These three APIs were enabled and read back on September 18, 2026.
This records project configuration, not a successful live OAuth test.

## OAuth web client and consent

In [Google Auth Platform](https://console.cloud.google.com/auth/overview?project=smart-data-campfire):

1. Complete **Branding** with the app name and support contact. Once the
   public pages in this release are deployed, use these Smart Data URLs:

   | Branding field | URL |
   | --- | --- |
   | Application home page | `https://chat.smartdata.net/about` |
   | Privacy policy | `https://chat.smartdata.net/privacy` |
   | Terms of service | `https://chat.smartdata.net/terms` |

   The homepage must describe the app and link to the same privacy policy
   used in OAuth; a login-only page is insufficient. Verify ownership of
   `smartdata.net` in Google Search Console with an account that is a
   project owner or editor. See Google's
   [brand verification requirements](https://support.google.com/cloud/answer/13464321).
   Review the policies for the hosting organization's actual practices;
   self-hosted workspace data is controlled by that organization, not
   automatically collected by the Smartfire project maintainers.
   Set `LEGAL_OPERATOR_NAME` and `LEGAL_CONTACT_EMAIL` for this installation
   before submission. See the [public policy configuration and review notes](public-policies.md).
2. Set **Audience** to **External**. Smart Data's two Workspace domains belong
   to separate organizations, so Internal would exclude one of them.
3. Create or reuse a **Web application** client under **Clients**. Register
   these exact **authorized redirect URIs**:

   ```text
   https://chat.smartdata.net/session/google/callback
   https://chat.smartdata.net/google/callback
   ```

4. Register this **authorized JavaScript origin** for the Drive Picker flow
   (no path):

   ```text
   https://chat.smartdata.net
   ```

5. Declare the scopes used by the enabled features under **Data Access**:

   | Feature | Scopes |
   | --- | --- |
   | Sign-in | `openid`, `email`, `profile` |
   | Calendar connection | `openid`, `email`, `https://www.googleapis.com/auth/calendar.events` |
   | Select a Drive file and offer recipient access | `https://www.googleapis.com/auth/drive.file` |
   | Optional Drive metadata previews and legacy search | `https://www.googleapis.com/auth/drive.metadata.readonly` |

6. Use **In production** publishing status for rollout. In Testing, Calendar
   authorizations and offline refresh tokens expire after seven days; basic
   identity-only sign-in has an exception. Publishing and verification are
   separate steps. See Google's [audience rules](https://support.google.com/cloud/answer/15549945).
7. Have administrators in **both** Workspace organizations allow the OAuth
   client for the required services. Google documents an
   [admin-trusted app verification exception](https://support.google.com/cloud/answer/13464323).
   Confirm the applicable exception or complete the required verification
   before wider rollout. External file sharing must also be permitted by
   each organization's Drive policies.

Google classifies `drive.file` as non-sensitive and
`drive.metadata.readonly` as restricted. The new sharing flow requests only
the former; metadata previews remain a separate opt-in. Do not replace it
with full Drive access. Restricted scopes can require verification and a
security assessment unless an applicable exception covers the deployment.
See [Google's scope guidance](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

## Picker key and host configuration

The Picker needs a browser API key restricted to `picker.googleapis.com`,
the app's HTTPS referrer, and Google's Picker iframe. For Smart Data, use
`https://chat.smartdata.net/*` and `https://docs.google.com/*`. Google
[requires the iframe referrer](https://developers.google.com/workspace/drive/picker/guides/web-picker)
for a website-restricted key. The `smartfire-drive-picker` key was created
with these restrictions on September 18, 2026.
An API key alone does not grant access to users' files; Google consent and
file selection are still required. Other deployments supply their own
project, origin, key, and domains.

Configure these environment variables on the application host:

| Variable | Value |
| --- | --- |
| `APP_URL` | `https://chat.smartdata.net` so background Calendar jobs produce complete event and meeting links |
| `GOOGLE_CLIENT_ID` | The OAuth Web application client ID |
| `GOOGLE_CLIENT_SECRET` | Its secret, stored securely on the server |
| `GOOGLE_SIGN_IN_DOMAINS` | `smartdata.net,cnbssoftware.com` for this installation |
| `GOOGLE_PICKER_API_KEY` | The restricted browser key |
| `GOOGLE_CLOUD_PROJECT_NUMBER` | `677278000060` for this installation |

Keep credentials out of source control and chat. OAuth credentials were
absent from the live Smart Data host when checked on September 18, 2026.

For the existing ONCE deployment, an `--env` update **replaces the complete
environment map**. Merge these values into the existing settings, preserve
all other values, and retain `SECRET_KEY_BASE` so existing encrypted Google
tokens remain readable. The normal image deployment deliberately omits
`--env`; adding GitHub workflow variables alone does not configure the app.
Use the [release procedure](../deploy/README.md) for the application update.

For this repository's protected GCP workflow, set these **production environment**
secrets and variables in GitHub Actions:

- Secret `GOOGLE_OAUTH_CLIENT_JSON`: the downloaded Web application credentials
  JSON, including the registered origins and callbacks.
- Secret `GOOGLE_PICKER_API_KEY`: the restricted browser key.
- Variable `GOOGLE_SIGN_IN_DOMAINS`: this installation's comma-separated domains.
  An empty value disables Google sign-in while retaining Calendar and Drive.
- Variable `GOOGLE_CLOUD_PROJECT_NUMBER`: this installation's project number.

Run **Deploy to GCP** with `configure_google=true`, first as a dry run. It validates
the OAuth project, origin, callbacks, and configuration before freezing writes.
After the image cutover, it merges the six Google/URL settings into the current
ONCE environment, restarts the same pinned image, and verifies every existing
environment value, other ONCE settings, and storage mounts. Secrets travel to the
VM through SSH standard input and are never printed. A protected settings backup
is retained under `/var/backups/smartfire-google-config-<timestamp>/`.
Leave `configure_google=false` for ordinary image-only upgrades.

## Member experience and rollout checks

- Each member connects Calendar once from their profile. Upcoming events
  they RSVP **Going** or **Maybe** to are copied to their primary calendar;
  edits and cancellations reconcile automatically. Google sign-in alone
  does not authorize Calendar. Google-side edits are not read back.
- Choosing a Drive file does not grant chat members access. The sender can
  attach with existing permissions, or review specific recipients and
  explicitly grant view access. Existing editor access is preserved.
  Grants persist independently of a draft, message, or room membership;
  future members are not automatically granted access.
- Keep metadata previews optional. They require their own consent and use
  the viewer's credentials, so attaching a file never exposes its metadata
  to a viewer who cannot access it.
- Test one user from each Workspace organization, an existing
  password-login member, cancelled consent, and rejected cross-domain
  sharing. Use agreed test accounts/files/events for live mutation tests.
- Confirm Calendar creation, update, decline/cancellation, and reconnect;
  confirm Drive attach-only, explicit reader grant, preserved editor,
  partial failure, and mobile/PWA recovery. Local tests use Google stubs and
  cannot establish live OAuth or organization-policy readiness.

Calendar currently records API failures and retries on the next relevant
event change; it has no scheduled retry worker. See
[Calendar behavior and cleanup limitations](google-calendar.md).
