# X post cards

A message containing an `https://x.com/<handle>/status/<id>` URL (or its
`twitter.com`, `www.`/`mobile.`, `/statuses/`, `/i/status/`, and
`/i/web/status/` variants) renders a live post card beneath the message:
author avatar, display name and @handle, the post text with URLs, mentions,
and hashtags linked, attached photos or a video poster, a quoted post when
present, the post time, reply/repost/like counts, and a "View on X" link.
The stored message body is never changed; references live in the
`twitter_post_references` join table and are re-synced when a message is
created or its Markdown source is edited.

## Where the data comes from

Cards resolve through the fxtwitter JSON API,
`GET https://api.fxtwitter.com/<handle>/status/<id>`, which needs no
credentials. Fetching happens in `Twitter::FetchPostJob`, never inline in
a request: on first reference, and once more when a new reference arrives
for a post whose recorded fetch error is older than 10 minutes. A post is
otherwise fetched once and never refreshed. The job is idempotent, safe
to enqueue concurrently, and records failures as `fetch_error` instead of
retrying forever.

The fetch client talks only to the fixed host `api.fxtwitter.com` — the
request path is built from the numeric post id and the validated handle,
never from a user-controlled host — with 5 s open / 10 s read timeouts, a
2 MB body cap, and a `Campfire-X-Post-Cards` user agent. Only
`https://pbs.twimg.com/…` and `https://video.twimg.com/…` URLs are kept
for avatars, media, and thumbnails; anything else is dropped and the card
renders without that media. Everything from the API is treated as
untrusted text: names and post text are stripped of tags and escaped on
render, and the response body is never logged.

After a fetch, the card partial is broadcast via Turbo Stream replace to
each room (or thread) with a referencing message, over the existing
membership-gated message stream, so cards fill in live.

## Limits and fallbacks

- At most 4 post links per message render cards, in order of appearance;
  repeats of one post render a single card.
- Before the fetch completes the card shows a compact "Loading post…"
  state. After a failure it shows a compact fallback with the @handle
  taken from the URL, "Couldn't load this post", and the "View on X" link.
- Long text clamps to 12 lines behind a "Show more" toggle. Videos and
  gifs show their poster with a play badge and link to the post; no player
  is embedded.
- Messages composed before this shipped keep rendering their stored
  OpenGraph embeds for non-post links, but embeds whose link is a post URL
  now render nothing: the reference sync picks the URL up from the message
  body and the new card replaces the old box.
