require "test_helper"

class Twitter::PostFetcherTest < ActiveSupport::TestCase
  setup do
    @post = Twitter::Post.create!(post_id: "424242", url: "https://x.com/jack/status/424242")
  end

  test "a successful fetch stores the card fields" do
    stub_post(status: "424242", handle: "jack", text: "just setting up my twttr")

    Twitter::PostFetcher.new(@post).fetch

    @post.reload
    assert_equal "https://x.com/jack/status/424242", @post.url
    assert_equal "jack", @post.author_handle
    assert_equal "jack", @post.author_name
    assert_equal "https://pbs.twimg.com/profile_images/1/avatar_200x200.jpg", @post.author_avatar_url
    assert_equal "just setting up my twttr", @post.text
    assert_equal Time.zone.at(1142974214), @post.posted_at
    assert_equal 18041, @post.replies
    assert_equal 124658, @post.reposts
    assert_equal 310826, @post.likes
    assert_equal [], @post.media
    assert_nil @post.quote
    assert_not_nil @post.fetched_at
    assert_nil @post.fetch_error
  end

  test "photos are kept with dimensions and alt text" do
    stub_post(status: "424242", handle: "jack", media: {
      "photos" => [
        { "type" => "photo", "url" => "https://pbs.twimg.com/media/A7EiDWcCYAAZT1D.jpg?name=orig", "width" => 800, "height" => 532 },
        { "type" => "photo", "url" => "https://pbs.twimg.com/media/other.jpg", "width" => 640, "height" => 480, "altText" => "A desk" }
      ]
    })

    Twitter::PostFetcher.new(@post).fetch

    assert_equal [
      { "type" => "photo", "url" => "https://pbs.twimg.com/media/A7EiDWcCYAAZT1D.jpg?name=orig",
        "thumbnail_url" => nil, "width" => 800, "height" => 532, "alt" => nil },
      { "type" => "photo", "url" => "https://pbs.twimg.com/media/other.jpg",
        "thumbnail_url" => nil, "width" => 640, "height" => 480, "alt" => "A desk" }
    ], @post.reload.media
  end

  test "a video keeps its thumbnail and a photo-only entry without a url is dropped" do
    stub_post(status: "424242", handle: "jack", media: {
      "photos" => [ { "type" => "photo", "url" => nil, "width" => 10, "height" => 10 } ],
      "videos" => [
        { "type" => "video", "url" => "https://video.twimg.com/amplify_video/1/vid/avc1/1280x720/x.mp4?tag=16",
          "thumbnail_url" => "https://pbs.twimg.com/amplify_video_thumb/1/img/x.jpg",
          "width" => 1280, "height" => 720 }
      ]
    })

    Twitter::PostFetcher.new(@post).fetch

    assert_equal [
      { "type" => "video", "url" => "https://video.twimg.com/amplify_video/1/vid/avc1/1280x720/x.mp4?tag=16",
        "thumbnail_url" => "https://pbs.twimg.com/amplify_video_thumb/1/img/x.jpg",
        "width" => 1280, "height" => 720, "alt" => nil }
    ], @post.reload.media
  end

  test "a quote is stored without media" do
    stub_post(status: "424242", handle: "jack", quote: {
      "url" => "https://x.com/NASA/status/123",
      "text" => "We go up",
      "author" => { "name" => "NASA", "screen_name" => "NASA" },
      "media" => { "photos" => [ { "type" => "photo", "url" => "https://pbs.twimg.com/media/q.jpg" } ] }
    })

    Twitter::PostFetcher.new(@post).fetch

    assert_equal(
      { "url" => "https://x.com/NASA/status/123", "author_name" => "NASA",
        "author_handle" => "NASA", "text" => "We go up" },
      @post.reload.quote
    )
  end

  test "a missing post records a not-found error" do
    stub_request(:get, "https://api.fxtwitter.com/jack/status/424242")
      .to_return(status: 200, body: { code: 404, message: "NOT_FOUND", tweet: nil }.to_json,
        headers: { "Content-Type" => "application/json" })

    Twitter::PostFetcher.new(@post).fetch

    @post.reload
    assert_not_nil @post.fetched_at
    assert_equal "Post not found on X", @post.fetch_error
  end

  test "a timeout records a fetch error instead of raising" do
    stub_request(:get, "https://api.fxtwitter.com/jack/status/424242").to_timeout

    Twitter::PostFetcher.new(@post).fetch

    @post.reload
    assert_not_nil @post.fetched_at
    assert_match "Could not reach X", @post.fetch_error
  end

  test "HTML in the name and text is stripped" do
    stub_post(status: "424242", handle: "jack", text: "hi <img src=x onerror=alert(1)> there",
      author_name: "<b>jack</b>")

    Twitter::PostFetcher.new(@post).fetch

    @post.reload
    assert_equal "hi  there", @post.text
    assert_equal "jack", @post.author_name
  end

  test "non-twimg avatar and media URLs are dropped" do
    stub_post(status: "424242", handle: "jack",
      avatar_url: "https://evil.example/avatar.jpg",
      media: {
        "photos" => [ { "type" => "photo", "url" => "https://evil.example/pic.jpg", "width" => 10, "height" => 10 } ],
        "videos" => [
          { "type" => "video", "url" => "https://evil.example/v.mp4",
            "thumbnail_url" => "https://evil.example/t.jpg", "width" => 10, "height" => 10 }
        ]
      })

    Twitter::PostFetcher.new(@post).fetch

    @post.reload
    assert_nil @post.author_avatar_url
    assert_equal [], @post.media
  end

  test "handle-less links are fetched through the i/status form" do
    post = Twitter::Post.create!(post_id: "424243", url: "https://x.com/i/status/424243")
    stub = stub_post(status: "424243", handle: "i", text: "just setting up my twttr")

    Twitter::PostFetcher.new(post).fetch

    assert_requested stub
    assert_equal "https://x.com/jack/status/424243", post.reload.url
  end

  test "an oversized body is rejected without parsing" do
    stub_request(:get, "https://api.fxtwitter.com/jack/status/424242")
      .to_return(status: 200, body: "x" * (2.megabytes + 1))

    Twitter::PostFetcher.new(@post).fetch

    assert_equal "Post response too large", @post.reload.fetch_error
  end

  private
    def stub_post(status:, handle:, text: "just setting up my twttr", author_name: "jack",
        avatar_url: "https://pbs.twimg.com/profile_images/1/avatar_200x200.jpg", media: nil, quote: nil)
      tweet = {
        "url" => "https://x.com/#{handle}/status/#{status}",
        "id" => status,
        "text" => text,
        "created_at" => "Tue Mar 21 20:50:14 +0000 2006",
        "created_timestamp" => 1142974214,
        "likes" => 310826,
        "retweets" => 124658,
        "replies" => 18041,
        "author" => { "name" => author_name, "screen_name" => "jack", "avatar_url" => avatar_url }
      }
      tweet["media"] = media if media
      tweet["quote"] = quote if quote

      stub_request(:get, "https://api.fxtwitter.com/#{handle}/status/#{status}")
        .with(headers: { "User-Agent" => "Campfire-X-Post-Cards" })
        .to_return(status: 200, body: { code: 200, message: "OK", tweet: tweet }.to_json,
          headers: { "Content-Type" => "application/json" })
    end
end
