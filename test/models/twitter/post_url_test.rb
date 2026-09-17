require "test_helper"

class Twitter::PostUrlTest < ActiveSupport::TestCase
  test "extracts a canonical x.com post URL" do
    assert_equal [ Twitter::PostUrl::Reference.new("jack", "20") ],
      Twitter::PostUrl.extract("see https://x.com/jack/status/20 please")
  end

  test "extracts twitter.com URLs with http, www, mobile, and the statuses plural" do
    assert_equal [ Twitter::PostUrl::Reference.new("jack", "20") ],
      Twitter::PostUrl.extract("http://twitter.com/jack/status/20")
    assert_equal [ Twitter::PostUrl::Reference.new("jack", "20") ],
      Twitter::PostUrl.extract("https://www.twitter.com/jack/status/20")
    assert_equal [ Twitter::PostUrl::Reference.new("jack", "20") ],
      Twitter::PostUrl.extract("https://mobile.x.com/jack/statuses/20")
  end

  test "extracts handle-less i/status and i/web/status URLs" do
    assert_equal [ Twitter::PostUrl::Reference.new(nil, "20") ],
      Twitter::PostUrl.extract("https://x.com/i/status/20")
    assert_equal [ Twitter::PostUrl::Reference.new(nil, "20") ],
      Twitter::PostUrl.extract("https://x.com/i/web/status/20")
  end

  test "ignores trailing paths, query strings, and fragments" do
    assert_equal [ Twitter::PostUrl::Reference.new("jack", "20") ],
      Twitter::PostUrl.extract("https://x.com/jack/status/20/photo/1?s=20&t=abc#frag")
  end

  test "dedupes by id and keeps at most four in order of appearance" do
    text = (1..6).map { |n| "https://x.com/user#{n}/status/#{n}" }.join(" ") +
      " again https://x.com/other/status/2"

    assert_equal [
      Twitter::PostUrl::Reference.new("user1", "1"),
      Twitter::PostUrl::Reference.new("user2", "2"),
      Twitter::PostUrl::Reference.new("user3", "3"),
      Twitter::PostUrl::Reference.new("user4", "4")
    ], Twitter::PostUrl.extract(text)
  end

  test "ignores non-post URLs" do
    assert_empty Twitter::PostUrl.extract("https://x.com/jack")
    assert_empty Twitter::PostUrl.extract("https://x.com/home")
    assert_empty Twitter::PostUrl.extract("https://x.com/jack/status/")
    assert_empty Twitter::PostUrl.extract("https://x.com/jack/status/abc")
    assert_empty Twitter::PostUrl.extract("https://x.com/0123456789abcdef/status/20")
    assert_empty Twitter::PostUrl.extract("https://example.com/jack/status/20")
    assert_empty Twitter::PostUrl.extract("ftp://x.com/jack/status/20")
    assert_empty Twitter::PostUrl.extract("just some text")
    assert_empty Twitter::PostUrl.extract(nil)
  end

  test "post_url? matches only post URLs" do
    assert Twitter::PostUrl.post_url?("https://x.com/jack/status/20")
    assert Twitter::PostUrl.post_url?("https://twitter.com/jack/status/20?s=20")
    assert Twitter::PostUrl.post_url?("https://x.com/i/web/status/20")
    assert_not Twitter::PostUrl.post_url?("https://x.com/jack")
    assert_not Twitter::PostUrl.post_url?("https://example.com/x/status/20")
    assert_not Twitter::PostUrl.post_url?(nil)
  end
end
