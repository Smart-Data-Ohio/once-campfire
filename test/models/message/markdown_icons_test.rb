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
    assert_equal 1, fragment.css("img").size, "expected the classless tracker image to be dropped: #{safe}"
  end

  test "presentation sanitizer rewrites a stale icon src to the current asset URL" do
    stale = <<~HTML
      <p><img class="icon icon--brand" src="/assets/icons/brands/openai-staledigest.svg" alt=":openai:" title="OpenAI" draggable="false"></p>
      <p><img class="icon icon--brand" src="https://cdn.example.com/assets/icons/brands/openai-staledigest.svg" alt=":openai:" title="OpenAI" draggable="false"></p>
    HTML

    icons = Nokogiri::HTML5.fragment(Message::Markdown.sanitize_presentation(stale)).css("img.icon--brand")

    assert_equal 2, icons.size, "expected both stale icons to survive with a rewritten src"
    icons.each do |icon|
      assert_equal Icons.brand_image_urls.fetch("openai"), icon["src"]
    end
  end

  test "presentation sanitizer drops icon markup with an unknown name" do
    unknown = %(<p><img class="icon icon--brand" src="/assets/icons/brands/nope_not_real-abc123.svg" alt=":nope_not_real:"></p>)

    assert_empty Nokogiri::HTML5.fragment(Message::Markdown.sanitize_presentation(unknown)).css("img")
  end

  test "presentation sanitizer drops a class-variant icon with a foreign src" do
    spoofed = %(<p><img class="icon ICON--BRAND" src="https://tracker.example/pixel.svg" alt="OpenAI"></p>)

    assert_empty Nokogiri::HTML5.fragment(Message::Markdown.sanitize_presentation(spoofed)).css("img")
  end

  test "presentation keeps mention avatars alongside rewritten icons" do
    message = create_markdown_message("Hi @[David] :openai:")
    fragment = Nokogiri::HTML5.fragment(present_markdown(message))

    assert_equal 2, fragment.css("img").size, "expected only the avatar and the icon: #{fragment.to_html}"
    assert_equal Icons.brand_image_urls.fetch("openai"), fragment.at_css("img.icon--brand")["src"]

    avatar = (fragment.css("img").to_a - fragment.css("img.icon--brand").to_a).sole
    assert_match %r{\A/users/[^/]+/avatar}, avatar["src"]
  end

  test "presentation keeps avatars served from the asset host" do
    with_asset_host "https://cdn.example.com" do
      html = %(<p><img src="https://cdn.example.com/users/TOKEN/avatar?v=1" width="48" height="48"></p>)

      assert_equal 1, Nokogiri::HTML5.fragment(Message::Markdown.sanitize_presentation(html)).css("img").size
    end
  end

  test "plain text keeps brand shortcodes and expands emoji shortcodes" do
    message = create_markdown_message(":openai: shipped :tada:")

    assert_equal ":openai: shipped 🎉", message.plain_text_body
  end

  test "renders a brand with an unresolvable asset as literal text" do
    Icons.stubs(:brand_image_urls).returns({})

    html = create_markdown_message("Hi :openai:").body.body.to_html

    assert_includes html, "Hi :openai:"
    assert_empty Nokogiri::HTML5.fragment(html).css("img")
  end

  test "presentation drops an icon whose asset cannot be resolved" do
    Icons.stubs(:brand_image_urls).returns({})

    stored = %(<p><img class="icon icon--brand" src="/assets/icons/brands/openai-old.svg" alt=":openai:"></p>)

    assert_empty Nokogiri::HTML5.fragment(Message::Markdown.sanitize_presentation(stored)).css("img")
  end

  test "shortcode-only messages get the large emoji treatment" do
    assert create_markdown_message(":openai::fire:🔥").plain_text_body.all_emoji?
    assert_not create_markdown_message("Hello :openai:").plain_text_body.all_emoji?
    assert_not create_markdown_message(":nope_not_real:").plain_text_body.all_emoji?
  end

  private
    def create_markdown_message(source)
      rooms(:pets).messages.create!(markdown_source: source, creator: users(:jason), client_message_id: SecureRandom.uuid)
    end

    # Mirrors MessagesHelper#markdown_message_presentation: attachment rendering
    # is what introduces mention avatars into the sanitizer input.
    def present_markdown(message)
      rendered = message.body.body.render_attachments do |attachment|
        attachment.node.tap do |node|
          if attachment.attachable.is_a?(User)
            node.inner_html = ApplicationController.render(partial: "users/mention", formats: :html, locals: { user: attachment.attachable })
          end
        end
      end

      Message::Markdown.sanitize_presentation(rendered.to_html)
    end

    def with_asset_host(host)
      original = Rails.configuration.action_controller.asset_host
      Rails.configuration.action_controller.asset_host = host
      yield
    ensure
      Rails.configuration.action_controller.asset_host = original
    end
end
