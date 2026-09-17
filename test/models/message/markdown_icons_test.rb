require "test_helper"

class Message::MarkdownIconsTest < ActiveSupport::TestCase
  test "renders a brand shortcode as an icon image" do
    message = create_markdown_message("Ship it with :openai: today")

    icon = Nokogiri::HTML5.fragment(message.body.body.to_html).at_css("img.icon--brand")

    assert icon, "expected an icon image in #{message.body.body.to_html}"
    assert_equal "icon icon--brand", icon["class"]
    assert_match %r{\A/assets/icons/brands/openai-[a-z0-9]+\.svg\z}, icon["src"]
    assert_equal ":openai:", icon["alt"]
    assert_equal "OpenAI", icon["title"]
    assert_equal "false", icon["draggable"]
    assert_equal "Ship it with :openai: today", message.markdown_source
  end

  test "leaves shortcodes literal inside inline code fenced blocks and link labels" do
    source = <<~'MARKDOWN'
      `:openai:`

      ```text
      :openai:
      ```

      [:openai: label](https://example.com/docs)
    MARKDOWN
    html = create_markdown_message(source).body.body.to_html
    fragment = Nokogiri::HTML5.fragment(html)

    assert_empty fragment.css("img")
    assert_match %r{<code>:openai:</code>}, html
    assert_match %r{<pre><code class="language-text">:openai:}, html
    assert_match %r{<a href="https://example.com/docs"[^>]*>:openai: label</a>}, html
  end

  test "resolves emoji shortcodes to their character" do
    message = create_markdown_message("Well done :thumbsup:")

    assert_includes message.body.body.to_html, "Well done 👍"
    assert_equal "Well done 👍", message.plain_text_body
  end

  test "leaves unknown shortcodes literal" do
    message = create_markdown_message("Hello :nope_not_real: friend")

    assert_empty Nokogiri::HTML5.fragment(message.body.body.to_html).css("img")
    assert_equal "Hello :nope_not_real: friend", message.plain_text_body
  end

  test "presentation sanitizer keeps icon markup and strips injected handlers" do
    stored = create_markdown_message("Hi :openai:").body.body.to_html
    injected = stored + %(<img src="https://tracker.example/pixel.svg" onerror="alert(1)">)

    safe = Message::Markdown.sanitize_presentation(injected)
    fragment = Nokogiri::HTML5.fragment(safe)

    icon = fragment.at_css("img.icon--brand")
    assert icon, "expected the icon to survive presentation sanitizing: #{safe}"
    assert_match %r{\A/assets/icons/brands/openai-[a-z0-9]+\.svg\z}, icon["src"]
    assert_empty fragment.css("[onerror]")
  end

  test "presentation sanitizer removes icon markup pointing outside the asset path" do
    spoofed = %(<p><img class="icon icon--brand" src="https://tracker.example/openai.svg" alt=":openai:"></p>)

    assert_empty Nokogiri::HTML5.fragment(Message::Markdown.sanitize_presentation(spoofed)).css("img")
  end

  test "plain text keeps brand shortcodes and expands emoji shortcodes" do
    message = create_markdown_message(":openai: shipped :tada:")

    assert_equal ":openai: shipped 🎉", message.plain_text_body
  end

  test "shortcode-only messages get the large emoji treatment" do
    assert create_markdown_message(":openai::fire:🔥").plain_text_body.all_emoji?
    assert_not create_markdown_message("Hello :openai:").plain_text_body.all_emoji?
  end

  private
    def create_markdown_message(source)
      rooms(:pets).messages.create!(markdown_source: source, creator: users(:jason), client_message_id: SecureRandom.uuid)
    end
end
