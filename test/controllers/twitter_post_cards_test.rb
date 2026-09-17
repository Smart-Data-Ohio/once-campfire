require "test_helper"
require "rake"

# The real :environment prerequisite is already loaded in tests; a no-op
# satisfies the backfill task's dependency without reinitializing.
Rake::Task.define_task(:environment)
load Rails.root.join("lib/tasks/twitter.rake")

class TwitterPostCardsTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"

    sign_in :david
    @room = rooms(:designers)
    @creator = users(:david)
  end

  test "a fetched post renders the card in the messages index" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "look https://x.com/jack/status/131",
      client_message_id: "x-card-index"
    )
    message.twitter_posts.first.update!(
      url: "https://x.com/jack/status/131",
      author_handle: "jack", author_name: "jack Bauer",
      author_avatar_url: "https://pbs.twimg.com/profile_images/1/avatar_200x200.jpg",
      text: "Hello @nasa, see https://example.com/x! #launch",
      posted_at: Time.zone.at(1142974214),
      replies: 18041, reposts: 124658, likes: 310826,
      media: [
        { "type" => "photo", "url" => "https://pbs.twimg.com/media/a.jpg", "thumbnail_url" => nil,
          "width" => 800, "height" => 532, "alt" => "A rocket" },
        { "type" => "video", "url" => "https://video.twimg.com/x.mp4",
          "thumbnail_url" => "https://pbs.twimg.com/t.jpg", "width" => 1280, "height" => 720, "alt" => nil }
      ],
      quote: { "url" => "https://x.com/NASA/status/123", "author_name" => "NASA",
        "author_handle" => "NASA", "text" => "We go up" },
      fetched_at: Time.current, fetch_error: nil
    )

    get room_messages_url(@room)

    assert_response :success
    within_twitter_cards(message) do
      assert_select "img.x-post-card__avatar[src='https://pbs.twimg.com/profile_images/1/avatar_200x200.jpg']"
      assert_select ".x-post-card__name", text: "jack Bauer"
      assert_select ".x-post-card__handle", text: "@jack"
      assert_select ".x-post-card__text", text: /Hello/
      assert_select ".x-post-card__text a[href='https://x.com/nasa']", text: "@nasa"
      assert_select ".x-post-card__text a[href='https://example.com/x']"
      assert_select ".x-post-card__text a[href='https://x.com/hashtag/launch']", text: "#launch"
      assert_select "img.x-post-card__photo[src='https://pbs.twimg.com/media/a.jpg']"
      assert_select "img.x-post-card__poster[src='https://pbs.twimg.com/t.jpg']"
      assert_select ".x-post-card__play"
      assert_select ".x-post-card__quote", text: /We go up/
      assert_select ".x-post-card__quote-handle", text: "@NASA"
      assert_select ".x-post-card__count", text: "18K replies"
      assert_select ".x-post-card__count", text: "125K reposts"
      assert_select ".x-post-card__count", text: "311K likes"
      assert_select ".x-post-card__link[href='https://x.com/jack/status/131']", text: "View on X"
    end
  end

  test "the loading state renders before the fetch completes" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "look https://x.com/jack/status/132",
      client_message_id: "x-card-loading"
    )

    get room_messages_url(@room)

    assert_response :success
    within_twitter_cards(message) do
      assert_select ".x-post-card__loading", text: "Loading post…"
      assert_select ".x-post-card__text", count: 0
    end
  end

  test "the fallback card renders after a failed fetch" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "look https://x.com/jack/status/133",
      client_message_id: "x-card-error"
    )
    message.twitter_posts.first.update!(fetched_at: Time.current, fetch_error: "Post not found on X")

    get room_messages_url(@room)

    assert_response :success
    within_twitter_cards(message) do
      assert_select ".x-post-card__error", text: /Couldn’t load this post/
      assert_select ".x-post-card__error-handle", text: "@jack"
      assert_select ".x-post-card__link[href='https://x.com/jack/status/133']", text: "View on X"
    end
  end

  test "a bot API message with a post link creates the reference and enqueues the fetch" do
    room = rooms(:watercooler)

    assert_enqueued_with(job: Twitter::FetchPostJob) do
      post room_bot_messages_url(room, users(:bender).bot_key),
        params: +"bot says https://x.com/jack/status/134"
    end

    assert_response :created
    assert_equal [ "134" ], Message.last.twitter_posts.map(&:post_id)
  end

  test "a legacy message with an OpenGraph embed renders the new card and not the old box" do
    message = create_legacy_post_message(post_id: "20", client_message_id: "x-card-legacy")
    assert_equal [ "20" ], message.twitter_posts.map(&:post_id)

    get room_messages_url(@room)

    assert_response :success
    within_twitter_cards(message) do
      assert_select ".x-post-card__text", text: "just setting up my twttr"
    end
    assert_select ".og-embed", count: 0
  end

  test "a legacy message without a post row keeps the old OpenGraph box" do
    message = create_legacy_post_message(post_id: "201", client_message_id: "x-card-legacy-noref")
    # Simulate a message the sync never reached: no reference, no post row.
    message.twitter_post_references.delete_all
    Twitter::Post.where(post_id: "201").delete_all

    get room_messages_url(@room)

    assert_response :success
    assert_select "##{dom_id(message)} .og-embed", count: 1
    assert_select "##{dom_id(message, :twitter_cards)}", count: 0
  end

  test "the backfill task turns legacy boxes into cards" do
    message = create_legacy_post_message(post_id: "202", client_message_id: "x-card-legacy-backfill")
    message.twitter_post_references.delete_all
    Twitter::Post.where(post_id: "202").delete_all

    # The x_card_post fixture also carries a post URL, so two match.
    assert_match(/Backfilled 2 messages/, run_backfill_task)
    assert_equal [ "202" ], message.reload.twitter_posts.map(&:post_id)

    get room_messages_url(@room)

    assert_response :success
    within_twitter_cards(message) do
      assert_select ".x-post-card__loading", text: "Loading post…"
    end
    assert_select ".og-embed", count: 0
  end

  private
    def create_legacy_post_message(post_id:, client_message_id:)
      # Not a solo link: a bare-link body takes the RemoveSoloUnfurledLinkText
      # path, which duplicates the box independently of this feature.
      body = <<~HTML
        <div>Look at this: https://x.com/jack/status/#{post_id}</div>
        <action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" href="https://x.com/jack/status/#{post_id}" url="https://pbs.twimg.com/profile_images/1/avatar_200x200.jpg" filename="jack (@jack)" caption="just setting up my twttr"></action-text-attachment>
      HTML
      @room.messages.create!(
        creator: @creator, body: body, client_message_id: client_message_id
      )
    end

    def run_backfill_task
      Rake::Task["twitter:backfill_references"].reenable
      capture_io { Rake::Task["twitter:backfill_references"].invoke }.first
    end

    def within_twitter_cards(message, &block)
      assert_select "##{dom_id(message, :twitter_cards)}", &block
    end

    def dom_id(*arguments)
      ActionView::RecordIdentifier.dom_id(*arguments)
    end
end
