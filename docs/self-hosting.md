## Self-hosting Smartfire

Smartfire's Docker image contains everything needed for a fully-functional, single-machine deployment.
This includes the web app, background jobs, caching, file serving, and SSL.
This guide covers running the Docker image by hand.

We recommend using `ghcr.io/smart-data-ohio/smartfire:main`, which tracks the default branch.
It changes with every merged pull request, so it's the newest - but least battle-tested - version of Smartfire.

Every push to the default branch also publishes a `sha-<short-sha>` tag for that exact commit,
so you can pin your deployment to a specific version if you want to avoid unexpected changes:

```bash
# exactly one commit
ghcr.io/smart-data-ohio/smartfire:sha-1a2b3c4
```

Version tags (`v*`) additionally publish semver tags and `latest`.

To run it you'll need three things:
1. a machine that runs Docker
2. a mounted volume (so that your database and file attachments are kept around between restarts)
3. some environment variables for configuration

If you'd rather build the image yourself from your own copy of the source, you can do that too:

```sh
docker build -t smartfire .
```

### Mounting a storage volume

Smartfire keeps all of its storage - the database and uploaded file attachments - inside the path `/rails/storage`.
By default Docker containers don't persist storage between runs, so you'll want to mount a persistent volume into that location.

The simplest way to do this is with the `--volume` flag with `docker run`. For example:

```sh
docker run --volume smartfire:/rails/storage ghcr.io/smart-data-ohio/smartfire:main
```

That will create a named volume (called `smartfire`) and mount it into the correct path.
Docker will manage where that volume is actually stored on your server.

You can also specify the data location yourself, mount a network drive, and more.
Check the Docker documentation to find out more about what's available.

### Configuring with environment variables

To configure your Smartfire installation, you can use environment variables.
At a minimum you'll want to configure your secret key and your SSL domain.

#### Secrets

Smartfire needs a few secret values that are specific to your instance:

- `SECRET_KEY_BASE` - the basis for cryptographic features like signed cookies. This should be a long, unguessable random string.
- `VAPID_PRIVATE_KEY`/`VAPID_PUBLIC_KEY` - a key pair used for sending Web Push notifications.

You can generate them by running:

```sh
docker run --rm ghcr.io/smart-data-ohio/smartfire:main script/admin/generate-secrets
```

It prints a fresh set of values ready to set as environment variables:

```
SECRET_KEY_BASE=...
VAPID_PRIVATE_KEY=...
VAPID_PUBLIC_KEY=...
```

Keep them safe and reuse the same values across restarts and upgrades - changing them later will invalidate sessions and push notification subscriptions.

#### SSL

If you want the Smartfire container to handle its own SSL (HTTPS) automatically (via Let's Encrypt), you just need to specify the domain name that you're running it on.
You can do that with the `TLS_DOMAIN` environment variable.

> [!NOTE]
> If you're using SSL, you'll want to allow traffic on ports 80 and 443.

So if you were running on `chat.example.com` you could enable SSL like this:

```sh
docker run --publish 80:80 --publish 443:443 --env TLS_DOMAIN=chat.example.com ...
```

If you are terminating SSL in some other proxy in front of Smartfire, or aren't using SSL at all (for example, if you want to run it locally on your laptop), then you should set `DISABLE_SSL=true` instead and just publish port 80:

```sh
docker run --publish 80:80 --env DISABLE_SSL=true ...
```

#### Error reporting (optional)

To enable error reporting to Sentry in production, supply your DSN in the `SENTRY_DSN` environment variable.
To disable Sentry initialization entirely, set `SKIP_TELEMETRY=true`.

#### Google sign-in (optional)

Set `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and a comma-separated
`GOOGLE_SIGN_IN_DOMAINS` allowlist. Register
`https://<your host>/session/google/callback` on the Google OAuth web client.
There are no default domains; each installation configures its own allowlist.
A missing or empty allowlist disables Google sign-in. Update the environment
and restart the application to add or remove domains without changing code.
Email/password login remains available
regardless of this setting. See [Google sign-in](google-sign-in.md) for
account linking, onboarding, and Google Cloud setup.

Calendar and Drive use additional configuration. Follow the
[Google Workspace deployment checklist](google-workspace-setup.md), including
`APP_URL` for links created by background Calendar jobs and the restricted
browser key for Drive Picker.

#### Public privacy and terms pages

`/about`, `/privacy`, and `/terms` are available without sign-in. Set
`LEGAL_OPERATOR_NAME` and `LEGAL_CONTACT_EMAIL` to identify the organization
hosting your workspace and its privacy contact. Review the texts against your
actual retention, backup, and access practices before publishing them as your
policies or submitting the app for Google verification. See
[public policy configuration](public-policies.md).

### Example

Putting it all together, here's a complete `docker run` invocation:

```sh
docker run \
  --name smartfire \
  --publish 80:80 --publish 443:443 \
  --restart unless-stopped \
  --volume smartfire:/rails/storage \
  --env SECRET_KEY_BASE=$YOUR_SECRET_KEY_BASE \
  --env VAPID_PUBLIC_KEY=$YOUR_PUBLIC_KEY \
  --env VAPID_PRIVATE_KEY=$YOUR_PRIVATE_KEY \
  --env TLS_DOMAIN=chat.example.com \
  ghcr.io/smart-data-ohio/smartfire:main
```

And here's an equivalent `docker-compose.yml` that you could use to run Smartfire via `docker compose up`:

```yaml
services:
  web:
    image: ghcr.io/smart-data-ohio/smartfire:main
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - SECRET_KEY_BASE=abcdefabcdef
      - TLS_DOMAIN=chat.example.com
      - VAPID_PRIVATE_KEY=myvapidprivatekey
      - VAPID_PUBLIC_KEY=myvapidpublickey
    volumes:
      - smartfire:/rails/storage

volumes:
  smartfire:
```

### First run

When you start Smartfire for the first time, you'll be guided through creating an admin account.

> [!TIP]
> The email address of this admin account will be shown on the login page so that people who forget their password know who to contact for help.
> (You can change this email later in the settings.)

Smartfire is single-tenant: any rooms designated "public" will be accessible by all users in the system.
To support entirely distinct groups of customers, you would deploy multiple instances of the application.

### Upgrading

All of Smartfire's state lives in the mounted volume, so upgrading is a matter of pulling a newer image and recreating the container:

```sh
docker pull ghcr.io/smart-data-ohio/smartfire:main
```

Any pending database migrations run automatically when the container boots.

### Backups

To back up your instance, back up the contents of the `/rails/storage` volume.

Because the SQLite database may be written to at any moment, you shouldn't copy its files directly while Smartfire is running.
Instead, first run `script/admin/prepare-backup` inside the running container to produce a consistent snapshot of the database (it's written to `storage/backups/` inside the volume):

```sh
docker exec smartfire script/admin/prepare-backup
```

(If you're using Docker Compose, replace `docker exec smartfire` with `docker compose exec web`)

Then archive the whole storage volume to a file on the host:

```sh
docker run --rm \
  --user root \
  --volume smartfire:/rails/storage \
  --volume "$PWD":/backup \
  ghcr.io/smart-data-ohio/smartfire:main \
  tar czf "/backup/smartfire-backup.tar.gz" -C /rails storage
```

This gives you a `smartfire-backup.tar.gz` in your current directory containing the database snapshot and all uploaded files.
Copy it somewhere safe, ideally off the machine.

To restore, extract the archive back into a (stopped) instance's volume, and replace the live database with the snapshot:

```sh
docker run --rm \
  --user root \
  --volume smartfire:/rails/storage \
  --volume "$PWD":/backup \
  ghcr.io/smart-data-ohio/smartfire:main \
  bash -c "tar xzf /backup/smartfire-backup.tar.gz -C /rails &&
           cp /rails/storage/backups/production.sqlite3 /rails/storage/db/production.sqlite3 &&
           rm -f /rails/storage/db/production.sqlite3-wal /rails/storage/db/production.sqlite3-shm &&
           chown -R rails:rails /rails/storage"
```

Then start Smartfire again.
