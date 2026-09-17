require "test_helper"

class Message::MarkdownWorkspaceIconsTest < ActiveSupport::TestCase
  setup do
    create_workspace_icon(name: "acme", title: "Acme Corp")
  end

  test "renders a workspace icon shortcode as a custom icon image" do
    message = create_markdown_message("Ship it with :acme: today")

    icon = Nokogiri::HTML5.fragment(message.body.body.to_html).at_css("img.icon--custom")

    assert icon, "expected a custom icon image in #{message.body.body.to_html}"
    assert_equal "icon icon--custom", icon["class"]
    assert_equal "/icons/acme", icon["src"]
    assert_equal ":acme:", icon["alt"]
    assert_equal "Acme Corp", icon["title"]
    assert_equal "false", icon["draggable"]
    assert_equal "Ship it with :acme: today", message.markdown_source
  end

  test "presentation sanitizer rewrites a stale custom icon src from its alt text" do
    stale = %(<p><img class="icon icon--custom" src="https://cdn.example.com/stale/acme.png" alt=":acme:" title="Acme Corp" draggable="false"></p>)

    icon = Nokogiri::HTML5.fragment(Message::Markdown.sanitize_presentation(stale)).at_css("img.icon--custom")

    assert icon, "expected the custom icon to survive with a rewritten src"
    assert_equal "/icons/acme", icon["src"]
  end

  test "a deleted workspace icon renders its literal shortcode" do
    stored = create_markdown_message("Ship it with :acme: today").body.body.to_html
    assert_includes stored, "icon--custom"

    WorkspaceIcon.find_by!(name: "acme").destroy

    presented = Message::Markdown.sanitize_presentation(stored)
    fragment = Nokogiri::HTML5.fragment(presented)

    assert_empty fragment.css("img")
    assert_includes fragment.text, "Ship it with :acme: today"
  end

  test "an unknown brand name falls back to its literal shortcode" do
    unknown = %(<p><img class="icon icon--brand" src="/assets/icons/brands/nope_not_real-abc123.svg" alt=":nope_not_real:"></p>)

    presented = Message::Markdown.sanitize_presentation(unknown)
    fragment = Nokogiri::HTML5.fragment(presented)

    assert_empty fragment.css("img")
    assert_equal ":nope_not_real:", fragment.text.strip
  end

  test "plain text keeps workspace icon shortcodes" do
    message = create_markdown_message(":acme: shipped :tada:")

    assert_equal ":acme: shipped 🎉", message.plain_text_body
  end

  test "plain text keeps the shortcode of a deleted workspace icon" do
    message = create_markdown_message("Ship it with :acme: today")
    WorkspaceIcon.find_by!(name: "acme").destroy

    assert_equal "Ship it with :acme: today", message.plain_text_body
  end

  test "custom-only messages get the large emoji treatment" do
    assert create_markdown_message(":acme::fire:🔥").plain_text_body.all_emoji?
    assert_not create_markdown_message("Hello :acme:").plain_text_body.all_emoji?
  end

  private
    def create_markdown_message(source)
      rooms(:pets).messages.create!(markdown_source: source, creator: users(:jason), client_message_id: SecureRandom.uuid)
    end
end
