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

Reactions accept a brand shortcode as boost content (validated against the
registry; unknown shortcodes are rejected) and render the same icon markup.
An emoji shortcode such as `:thumbsup:` is stored as the character itself, so
it behaves exactly like an emoji typed directly. The eight quick reactions are
unchanged.

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
sanitizer keeps this markup and drops any icon image whose `src` is not one of
the registry's digested asset URLs.

`plain_text_body` yields the emoji character for emoji shortcodes and keeps
the `:name:` text for brand icons, so search, notifications, exports, and bot
integrations see something readable.

## License

The SVGs are from [Simple Icons](https://github.com/simple-icons/simple-icons),
vendored from version **15.22.0** of the `simple-icons` npm package under the
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)
dedication; see `app/assets/images/icons/brands/LICENSE.md`. That version was
the newest release still shipping `openai.svg`; `microsoft`, `amazon`,
`amazonaws`, `xai`, and `deepseek` are absent from it and were skipped. The
depicted logos remain trademarks of their respective owners.
