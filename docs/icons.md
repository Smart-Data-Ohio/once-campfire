# Brand icons and emoji shortcodes

Members can type Discord-style shortcodes such as `:openai:`, `:anthropic:`,
or `:thumbsup:` in a message or a reaction. Brand shortcodes render as inline
SVG icons; emoji shortcodes resolve to their Unicode character through every
alias the `gemoji` gem knows. `markdown_source` stays verbatim, so editing and
search keep working on the typed text.

## The set

The workspace ships 27 built-in brand icons, registered in `config/icons.yml`
with a `name`, `file`, `title`, and optional `aliases` (for example `gpt` for
`openai`, `gemini` for `googlegemini`, `hf` for `huggingface`):

`anthropic`, `apple`, `claude`, `cloudflare`, `cursor`, `discord`, `docker`,
`figma`, `github`, `githubcopilot`, `googlegemini`, `google`, `huggingface`,
`kubernetes`, `linear`, `linux`, `meta`, `mistralai`, `notion`, `nvidia`,
`ollama`, `openai`, `perplexity`, `slack`, `stripe`, `vercel`, `x`.

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

## License

The SVGs are from [Simple Icons](https://github.com/simple-icons/simple-icons),
vendored from version **15.22.0** of the `simple-icons` npm package under the
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)
dedication; see `app/assets/images/icons/brands/LICENSE.md`. That version was
the newest release still shipping `openai.svg`; `microsoft`, `amazon`,
`amazonaws`, `xai`, and `deepseek` are absent from it and were skipped. The
depicted logos remain trademarks of their respective owners.
