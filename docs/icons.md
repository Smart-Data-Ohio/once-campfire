# Brand icons and emoji shortcodes

Members can type Discord-style shortcodes such as `:openai:`, `:anthropic:`,
or `:thumbsup:` in a message or a reaction. Brand shortcodes render as inline
SVG icons; emoji shortcodes resolve to their Unicode character through every
alias the `gemoji` gem knows. `markdown_source` stays verbatim, so editing and
search keep working on the typed text.

## The set

The workspace ships 33 built-in brand icons, registered in `config/icons.yml`
with a `name`, `file`, `title`, and optional `aliases` (for example `gpt` for
`openai`, `gemini` for `googlegemini`, `hf` for `huggingface`):

`anthropic`, `apple`, `claude`, `cloudflare`, `cursor`, `discord`, `docker`,
`figma`, `github`, `githubcopilot`, `googlegemini`, `google`, `huggingface`,
`kubernetes`, `linear`, `linux`, `meta`, `mistralai`, `notion`, `nvidia`,
`ollama`, `openai`, `perplexity`, `slack`, `stripe`, `vercel`, `x`,
`microsoft`, `azure`, `aws`, `xai`, `grok`, `deepseek`.

Brand names win over gemoji aliases on conflict: `:x:` and `:apple:` render
the company logos, not ❌ and 🍎. Shortcodes expand after Markdown renders,
only inside text nodes — never inside inline code, fenced blocks, link labels,
or mention attachments. Unknown shortcodes such as `:nope_not_real:` stay
literal.

Reactions accept a brand shortcode as boost content and render the same
icon markup. An emoji shortcode such as `:thumbsup:` is stored as the
character itself, so it behaves exactly like an emoji typed directly. A
reaction whose shortcode the registry does not know is stored as the literal
text, exactly as typed. Brand aliases are canonicalised on save, so `:gpt:`
is stored as `:openai:` and shares its reaction chip. The eight quick
reactions are unchanged.

## Adding an icon

1. Copy the `<slug>.svg` from the pinned Simple Icons release (see below) into
   `app/assets/images/icons/brands/`, unmodified.
2. Add a `name`, `file`, and `title` entry to `config/icons.yml`, plus any
   `aliases`. Names are lowercase `[a-z0-9_]+`.
3. Restart the server: the `Icons` registry loads once at boot.

## Autocomplete

Typing `:` followed by at least two characters in the Markdown composer shows
up to 8 matches from `GET /autocompletable/icons?q=<text>` (JSON: `name`,
`title`, `kind`, `image` for brands, `character` for emoji), authenticated
like the member autocomplete. Selecting a suggestion inserts `:name:` plus a
space. `::` and a `:` inside a word (`12:30`, `http://`) never open it. The
free-text boost input offers the same `:` completions.

## Rendering and theming

A brand icon renders as
`<img class="icon icon--brand" src="<digested asset path>" alt=":name:" title="<title>" draggable="false">`.
The `.icon--brand` rule in `app/assets/stylesheets/icons.css` sizes it to
`1.2em` inline, so icons scale with emoji-only messages. Simple Icons ship
black, so the dark theme inverts them through the `--icon-filter` custom
property defined in `app/assets/stylesheets/colors.css`. The presentation
sanitizer rewrites each icon's `src` from the `:name:` in its alt text, so
stored bodies keep rendering across digest changes and asset host moves, and
drops any image that is neither a known icon nor a mention avatar.

`plain_text_body` yields the emoji character for emoji shortcodes and keeps
the `:name:` text for brand icons, so search, notifications, exports, and bot
integrations see something readable.

## Workspace icons

Administrators can upload their own icons from the **Icons** page under
Account settings (`GET /account/icons`; other members get 403). Each icon
has a shortcode `name`, a `title`, and one attached image, and members then
use it exactly like a built-in brand icon: `:name:` in messages and
reactions, `:` autocomplete, inline at text size in both themes.

Names are unique, lowercase `[a-z0-9_]{2,32}`, and may not equal any
built-in brand name or alias; like brands, they may shadow a gemoji alias.
Titles are 1 to 60 characters. The registry resolves brands first, then
workspace icons, then gemoji, reading uploads through a per-process memo
that re-checks a version stamp at most once per second — a new upload shows
up everywhere within a second without a restart.

Formats and limits: `image/svg+xml` or `image/png`, at most 256 KB. PNGs
must be square and at least 64 px on each side. SVGs are parsed with
Nokogiri and **rejected** (never cleaned) when they contain any `script`
element, any attribute whose name starts with `on`, `foreignObject`,
`image`, a `style` element or attribute with `url(`, a `use`, `a`,
`feImage`, or any other element with an `href` or `xlink:href` that is not
a `#fragment`, an external entity or DOCTYPE, a non-`svg` root, malformed
XML, or a nested `svg` from a different namespace.

Icons are served from the stable route `GET /icons/:name` to any signed-in
user (404 for unknown names and signed-out users), streaming the attached
blob with `Cache-Control: private, max-age=3600` and an `ETag` from the
blob checksum, so conditional GETs work. Active Storage blob URLs never
appear in message HTML. SVGs are served as `image/svg+xml`, inline, with
`X-Content-Type-Options: nosniff` and
`Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'`,
so even a missed vector cannot run scripts.

A workspace icon renders as
`<img class="icon icon--custom" src="/icons/<name>" alt=":name:" title="<title>" draggable="false">`,
sized like `.icon--brand` but without the dark-theme invert filter, since
uploads are full-colour. The presentation sanitizer rewrites the `src` from
the alt text the same way it does for brands. Deleting an icon removes the
row and its blob; messages that used it then render the literal `:name:`
text, and boosts keep their stored `:name:` content. An icon whose name is
no longer known renders as its alt text rather than a broken image, for
brand and workspace icons alike.

## Icons as room and bot avatars

Rooms and bots can use any icon from the set as their avatar. `rooms.icon_name`
and `users.icon_name` (bots only) hold a nullable shortcode, normalized on
write through `Icons.normalize_name` (`:name:` colons stripped, downcased) and
validated to nil or a name `Icons.find` resolves. A workspace icon deleted
afterwards leaves the stored name resolving to nil, and every renderer falls
back to its default marker instead of raising.

`icon_avatar_tag(icon_name, size:)` in `app/helpers/icons_avatar_helper.rb`
renders any resolvable icon at avatar sizes: brand and workspace icons as
`<img>` from their existing paths with `alt` set to the icon title, emoji as
a `<span>` glyph with an accessible name. It returns nil for an unresolvable
name. Rooms show the icon at 24px in sidebar rows
(`users/sidebars/rooms/_shared` and `_voice`), at 32px in the room header
(`rooms/show/_header_identity`), and at 16px next to the room name in search
results (`messages/_message`), each in place of the plain `#` or `→` marker;
rooms without an icon render exactly as before. Bots show the icon through
`avatar_tag` when no picture is uploaded — an uploaded picture always wins —
while the avatars controller keeps serving the picture or initials as today.

Each room edit form and the bot edit form has an **Icon** field holding the
shortcode, with the existing `:` icon autocomplete wired to the same
`markdown-autocomplete` Stimulus controller and `autocompletable/icons`
endpoint, a live preview next to the input, and a **Remove** button that
clears it. Room fields follow the existing room permissions (administrators
or the room creator); the bot field follows the bot edit permission
(administrators or the agent owner).

Saving a room re-broadcasts its sidebar row and its header identity over the
existing `:rooms` streams, so everyone who can see the room picks the new
icon up without a reload. Saving a bot bumps `updated_at` like any other
update, which busts `fresh_user_avatar_path` caches through its `v`
parameter. JSON clients get `icon_name` (nullable) on rooms and on users plus
`icon_avatar_url` (nullable, nil for emoji) on users, in `users/_user` and in
the `message_payload` creator and room hashes.

## License

The SVGs come from two sources; see
`app/assets/images/icons/brands/LICENSE.md` for provenance. Twenty-seven are
from [Simple Icons](https://github.com/simple-icons/simple-icons), vendored
from version **15.22.0** of the `simple-icons` npm package under the
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)
dedication; that version was the newest release still shipping `openai.svg`.
The other six (`microsoft`, `azure`, `aws`, `xai`, `grok`, `deepseek`) are the
monochrome files from version **1.95.0** of the `@lobehub/icons-static-svg`
npm package, published under the
[MIT license](https://github.com/lobehub/lobe-icons) by LobeHub; see
`app/assets/images/icons/brands/LICENSE-lobehub.md`. Amazon (retail) exists in
neither source and has no icon. The depicted logos remain trademarks of their
respective owners.
