# Workspace and Markdown

The signed-in workspace places channels and direct messages in a left sidebar, with the conversation and composer beside it. The header keeps search, room settings, notifications, and huddle access available. On small screens, the navigation opens in a drawer. Light and dark colors follow the operating system setting.

Channel switches use Turbo navigation: the current conversation stays visible until the destination is ready, without a top-of-screen progress bar. This also applies to Back/Forward channel navigation and shared message links. On mobile, selecting a channel closes the navigation drawer.

## Channel members

The right sidebar lists active members with access to the current channel, grouped into Online and Offline. Online means the member has an authenticated connection to the workspace, including when they are viewing another channel. Viewing the list does not mark other channels as read. Multiple tabs count independently: closing one keeps the member online while another remains connected, and logging out ends presence for that login session.

The list updates when your connection is established and refreshes every 12 seconds while visible. Connections send a heartbeat every 25 seconds; a lost connection that cannot close cleanly expires after 90 seconds. The channel membership check also applies to the member-list endpoint, so private-channel rosters are not available to nonmembers. Signed-out JSON requests receive an empty 401 response.

At widths of 1280 pixels and above, the list opens beside the conversation and can be hidden from the header. On smaller screens, **Show members** opens a drawer. Escape or **Close members** closes it and returns focus to the opener. The drawer keeps keyboard focus inside while open.

## Writing messages

New messages use Markdown in a compact, automatically growing message box. Type Markdown syntax directly for headings, bold, italics, strikethrough, links, quotes, lists, tables, task lists, inline code, and fenced code blocks.

On a desktop, Enter sends, Shift+Enter inserts a line break, and Ctrl/Cmd+Enter sends. On a touch device or narrow screen, Enter inserts a line break; use the send button to send. Ctrl/Cmd+B, Ctrl/Cmd+I, and Ctrl/Cmd+K format the selection. Use attachments for images and other files; file paste and file drop continue to work. Links to X posts render as live cards under the message; see [X post cards](x-posts.md).

Type `@` to find a member of the current room. Selecting a suggestion inserts `@[Display Name]`. Only an exact, unique, active room member is resolved to a mention. Ambiguous names and names outside the room stay plain text. Mentions inside code or links do not notify anyone. The resolved identity is saved with the message, so a later display-name change does not redirect an existing mention.

Discord-style shortcodes such as `:openai:` or `:thumbsup:` render inline as brand icons or emoji, with `:` autocomplete in the composer and the reaction input. Shortcodes inside code or link labels stay literal. See [Brand icons and emoji shortcodes](icons.md).

Editing a Markdown message restores its original source in the same plain-text editor. Messages created before Markdown was introduced keep their existing rich-text editor when edited.

If sending fails, the composer keeps the draft. **Restore draft** recovers a failed message while preserving any newer text you have started writing.

## Sharing code

Put code between triple backticks, with an optional language after the opening backticks:

````markdown
```typescript
interface Person { name: string }
const person: Person = { name: "Sam" }
```
````

Sent code blocks use VS Code's built-in **Light+** and **Dark+** themes and TextMate language grammars through Shiki, in channels, threads, and search results. Colors follow the system light or dark theme, and long lines scroll inside the block on narrow screens. **Copy code** copies the original code, including indentation and line breaks, without the fence markers. Project-aware semantic highlighting provided by VS Code extensions and language servers is not part of chat rendering.

Supported languages include Bash (`bash`, `sh`), C (`c`), C++ (`cpp`, `c++`), C# (`csharp`, `cs`, `c#`), CSS, Diff, Dockerfile, Go, Java, JavaScript (`javascript`, `js`, `jsx`), JSON, PowerShell, Python (`python`, `py`), Ruby, Rust, SQL, TypeScript (`typescript`, `ts`, `tsx`), HTML/XML (`html`, `xml`), and YAML (`yaml`, `yml`). Language labels are case-insensitive.

Omit the language to detect it automatically. Use `text`, `txt`, or `plaintext` to preserve a block without syntax colors. Unknown language labels also stay plain text. Inline code between single backticks keeps its compact code style. The composer continues to show the original Markdown source when writing or editing.

## Interaction direction

Keep chat interactions close to Discord's model: replies stay visible in the channel with compact context and a link to the original message, mentions are direct and predictable, and separate threads are an intentional choice rather than the default way to follow a conversation. Replies currently insert a Markdown block quote with an original-message link; replacing that quote with compact linked reply context remains future work.

## Rendering and storage

`messages.markdown_source` is nullable. A value selects Markdown; `nil` retains the existing rich-text behavior. There is no conversion of old messages. The rendered body is stored through Action Text so existing search, notifications, exports, and bot integrations continue to consume the message body.

Commonmarker renders Markdown with raw HTML disabled. A separate allowlist sanitizes the generated markup, and a second presentation sanitizer handles the existing server-rendered mention attachments. Markdown input is limited to 50,000 characters.

The compatibility preview endpoint remains available at `POST /rooms/:room_id/messages/preview`, with a `message[markdown_source]` field. It returns `{ "html": "..." }`. Message create/update requests accept the same source field; when present, the server renders the body instead of trusting a supplied HTML body.

## Local validation

The browser coverage in `test/system/workspace_markdown_test.rb` exercises send and receive, editing, keyboard input, sanitization, replies, attachments, mentions, system theme changes, and mobile navigation. `test/system/channel_members_test.rb` checks channel access, workspace presence across channels and tabs, sign-out, mobile member navigation, and composer alignment. The original messaging and huddle browser tests provide regression coverage for the shared workspace.

`test/system/code_highlighting_test.rb` covers language aliases, exact code text and copying, plain-text fallbacks, search results, threads, theme colors, and narrow-screen scrolling.

The highlighter loads lazily in a background worker, independently of channel navigation and composition. Code stays readable and copyable if highlighting is unavailable. The worker, grammars, and two themes are served locally; no code is sent to an external service. Rebuild the checked-in worker with `npm ci && npm run build` in `script/code-highlighter`, and run its grammar/theme checks with `npm test`. Highlight.js provides detection for unlabelled blocks; Shiki supplies the syntax tokens and colors.

Apply the database migration and restart Rails when updating an existing installation. See [huddles.md](huddles.md) for the separately configured huddle services.
