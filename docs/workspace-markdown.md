# Workspace and Markdown

The signed-in workspace places channels and direct messages in a left sidebar, with the conversation and composer beside it. The header keeps search, room settings, notifications, and huddle access available. On small screens, the navigation opens in a drawer. Light and dark colors follow the operating system setting.

## Writing messages

New messages use Markdown. The formatting buttons insert Markdown into the source, and **Preview** shows the server-rendered result before sending. Supported formatting includes headings, bold, italics, strikethrough, links, quotes, lists, tables, task lists, inline code, and fenced code blocks.

On a desktop, Enter sends, Shift+Enter inserts a line break, and Ctrl/Cmd+Enter sends. On a touch device or narrow screen, Enter inserts a line break; use the send button to send. Ctrl/Cmd+B, Ctrl/Cmd+I, and Ctrl/Cmd+K format the selection. Use attachments for images and other files; file paste and file drop continue to work.

Type `@` to find a member of the current room. Selecting a suggestion inserts `@[Display Name]`. Only an exact, unique, active room member is resolved to a mention. Ambiguous names and names outside the room stay plain text. Mentions inside code or links do not notify anyone. The resolved identity is saved with the message, so a later display-name change does not redirect an existing mention.

Editing a Markdown message restores its original source. Existing messages keep their rich-text editor. The **Rich text** button also remains available for new messages, including Campfire's existing pasted-link previews.

If sending fails, the composer keeps the draft. **Restore draft** recovers a failed message while preserving any newer text you have started writing.

## Rendering and storage

`messages.markdown_source` is nullable. A value selects Markdown; `nil` retains the existing rich-text behavior. There is no conversion of old messages. The rendered body is stored through Action Text so existing search, notifications, exports, and bot integrations continue to consume the message body.

Commonmarker renders Markdown with raw HTML disabled. A separate allowlist sanitizes the generated markup, and a second presentation sanitizer handles the existing server-rendered mention attachments. Preview uses the same rendering path as saved messages, requires access to the room, and does not create a message. Markdown input is limited to 50,000 characters.

The preview endpoint is `POST /rooms/:room_id/messages/preview`, with a `message[markdown_source]` field. It returns `{ "html": "..." }`. Message create/update requests accept the same source field; when present, the server renders the body instead of trusting a supplied HTML body.

## Local validation

The browser coverage in `test/system/workspace_markdown_test.rb` exercises preview, send and receive, editing, keyboard input, sanitization, replies, attachments, mentions, system theme changes, and mobile navigation. The original messaging and huddle browser tests provide regression coverage for the shared workspace.

Apply the database migration and restart Rails when updating an existing installation. See [huddles.md](huddles.md) for the separately configured huddle services.
