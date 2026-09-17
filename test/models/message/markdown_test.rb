require "test_helper"

class Message::MarkdownTest < ActiveSupport::TestCase
  test "preserves exact source and stores sanitized rendered HTML in Action Text" do
    source = "# Ship it\n\n**bold** and ~~done~~\n\n```ruby\nputs \"hi\"\n```\n"
    message = create_markdown_message(source)

    assert_equal source, message.reload.markdown_source
    assert message.markdown?
    assert_match %r{<h1>Ship it</h1>}, message.body.body.to_html
    assert_match %r{<strong>bold</strong> and <del>done</del>}, message.body.body.to_html
    assert_match %r{<pre><code class="language-ruby">puts "hi"\n</code></pre>}, message.body.body.to_html
    assert_equal "Ship it\n\nbold and done\n\nputs \"hi\"", message.plain_text_body
  end

  test "supports GFM tables task lists ordered lists and quotes" do
    source = <<~MARKDOWN
      > Ready

      3. third
      4. fourth

      - [x] shipped
      - [ ] pending

      | Status | Owner |
      | --- | --- |
      | Ready | David |
    MARKDOWN

    html = create_markdown_message(source).body.body.to_html

    assert_match %r{<blockquote>}, html
    assert_match %r{<ol start="3">}, html
    assert_match %r{<input type="checkbox" checked="" disabled="disabled"> shipped}, html
    assert_match %r{<input type="checkbox" disabled="disabled"> pending}, html
    assert_match %r{<table>.*<th>Status</th>.*<td>Ready</td>.*</table>}m, html
  end

  test "removes raw HTML unsafe links handlers and images while preserving code literally" do
    source = <<~MARKDOWN
      <script>alert("raw")</script>

      <img src="https://tracker.example/pixel" onerror="alert(1)">

      [script](javascript:alert(1)) [data](data:text/html,pwned)
      ![remote](https://tracker.example/image.svg)

      ```html
      <img src=x onerror="alert(1)">
      ```
    MARKDOWN

    html = create_markdown_message(source).body.body.to_html

    fragment = Nokogiri::HTML5.fragment(html)
    assert_empty fragment.css("script, img, [onerror]")
    assert_empty fragment.css("a[href^='javascript:'], a[href^='data:']")
    assert_match %r{<a>script</a>}, html
    assert_match %r{<a>data</a>}, html
    assert_match %r{<pre><code class="language-html">&lt;img src=x onerror="alert\(1\)"&gt;}, html
  end

  test "safe links open outside Smartfire with opener protections" do
    html = create_markdown_message("[Docs](https://example.com/docs \"Read\")").body.body.to_html

    assert_match %r{<a href="https://example.com/docs" title="Read" target="_blank" rel="nofollow noopener noreferrer">Docs</a>}, html
  end

  test "resolves a unique readable mention to a stored User attachment" do
    message = create_markdown_message("Hi @[David]")

    assert_equal [ users(:david) ], message.mentionees
    assert_match %r{<action-text-attachment sgid="#{Regexp.escape(users(:david).attachable_sgid)}" content-type="application/vnd\.campfire\.mention"}, message.body.body.to_html

    users(:david).update!(name: "David Renamed")
    assert_equal [ users(:david) ], message.reload.mentionees
    assert_equal "Hi @[David]", message.markdown_source
    assert_equal "Hi @David Renamed", message.plain_text_body
  end

  test "does not resolve mentions in code links escaped source or nonmembers" do
    source = <<~'MARKDOWN'
      `@[David]`

      ```text
      @[David]
      ```

      [@[David]](https://example.com/@[David] "Ping @[David]")

      \@[David] @[Kevin]
    MARKDOWN
    message = create_markdown_message(source)
    html = message.body.body.to_html

    assert_includes source, "\\@[David]"
    assert_empty message.mentionees
    assert_no_match /SMARTFIREMENTION/, html
    assert_match %r{<code>@\[David\]</code>}, html
    assert_match %r{<pre><code class="language-text">@\[David\]}, html
    assert_match %r{href="https://example.com/@\[David\]" title="Ping @\[David\]"}, html
    assert_includes message.plain_text_body, "@[David] @[Kevin]"
  end

  test "does not guess when duplicate room members share a display name" do
    duplicate = User.create!(name: "David")
    assert_includes rooms(:pets).users, duplicate

    message = create_markdown_message("Hi @[David]")

    assert_empty message.mentionees
    assert_equal "Hi @[David]", message.plain_text_body
    assert_no_match /action-text-attachment/, message.body.body.to_html
  end

  test "rejects oversized and blank markdown but permits blank markdown with an attachment" do
    oversized = Message.new(
      room: rooms(:pets), creator: users(:jason), markdown_source: "x" * (Message::Markdown::SOURCE_LIMIT + 1)
    )
    blank = Message.new(room: rooms(:pets), creator: users(:jason), markdown_source: " \n")

    assert_not oversized.valid?
    assert_not blank.valid?

    attached = Message.new(room: rooms(:pets), creator: users(:jason), markdown_source: "")
    attached.attachment.attach io: StringIO.new("hello"), filename: "hello.txt", content_type: "text/plain"
    assert attached.valid?
  end

  private
    def create_markdown_message(source)
      rooms(:pets).messages.create!(markdown_source: source, creator: users(:jason), client_message_id: SecureRandom.uuid)
    end
end
