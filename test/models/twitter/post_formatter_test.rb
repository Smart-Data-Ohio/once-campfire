require "test_helper"

class Twitter::PostFormatterTest < ActiveSupport::TestCase
  test "escapes HTML and preserves line breaks" do
    formatted = Twitter::PostFormatter.format("<b>hi</b>\nbye")

    assert_equal "&lt;b&gt;hi&lt;/b&gt;<br>bye", formatted.to_s
    assert_predicate formatted, :html_safe?
  end

  test "links URLs, mentions, and hashtags" do
    formatted = Twitter::PostFormatter.format("Hi @jack, see https://x.com/a/status/1! #news").to_s

    assert_includes formatted, %(<a href="https://x.com/jack" target="_blank" rel="noopener noreferrer">@jack</a>)
    assert_includes formatted, %(<a href="https://x.com/a/status/1" target="_blank" rel="noopener noreferrer">https://x.com/a/status/1</a>)
    assert_includes formatted, %(<a href="https://x.com/hashtag/news" target="_blank" rel="noopener noreferrer">#news</a>)
  end

  test "leaves emails and mentions inside URLs alone" do
    formatted = Twitter::PostFormatter.format("mail a@b.co or visit https://x.com/@jack#frag").to_s

    assert_no_match %r{x.com/a}, formatted
    assert_equal 1, formatted.scan("<a ").size
    assert_includes formatted, %(<a href="https://x.com/@jack#frag" target="_blank" rel="noopener noreferrer">https://x.com/@jack#frag</a>)
  end

  test "keeps entities and punctuation intact" do
    formatted = Twitter::PostFormatter.format("it's <3 (https://x.com/a/status/2).").to_s

    assert_includes formatted, "it&#39;s &lt;3"
    assert_includes formatted, %((<a href="https://x.com/a/status/2" target="_blank" rel="noopener noreferrer">https://x.com/a/status/2</a>).)
  end

  test "clamp? trips on long text or many breaks" do
    assert_not Twitter::PostFormatter.clamp?("short")
    assert Twitter::PostFormatter.clamp?("x" * 481)
    assert Twitter::PostFormatter.clamp?("line\n" * 12)
  end

  test "plain escapes without linking" do
    assert_equal "a&lt;b&gt;<br>@c", Twitter::PostFormatter.plain("a<b>\n@c").to_s
  end
end
