require "test_helper"

class Twitter::PostTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @room = rooms(:designers)
    @creator = users(:david)
  end

  test "for_reference upserts by post id and keeps ids as strings" do
    first = Twitter::Post.for_reference(post_id: "266031293945503744", url: "https://x.com/a/status/266031293945503744")
    second = Twitter::Post.for_reference(post_id: "266031293945503744", url: "https://x.com/b/status/266031293945503744")

    assert_equal first, second
    assert_equal "266031293945503744", first.post_id
    assert_equal 1, Twitter::Post.where(post_id: "266031293945503744").count
  end

  test "needs_fetch? is true until fetched and after a stale error" do
    post = Twitter::Post.for_reference(post_id: "100")
    assert post.needs_fetch?

    post.update!(fetched_at: 1.hour.ago, fetch_error: nil)
    assert_not post.needs_fetch?

    post.update!(fetched_at: 11.minutes.ago, fetch_error: "Post not found on X")
    assert post.needs_fetch?

    post.update!(fetched_at: 9.minutes.ago, fetch_error: "Post not found on X")
    assert_not post.needs_fetch?
  end

  test "claim_fetch_request! grants one fetch per post per ten minutes" do
    post = Twitter::Post.for_reference(post_id: "101")

    assert post.claim_fetch_request!
    assert post.fetch_requested_recently?
    assert_not post.claim_fetch_request!

    post.update_column(:fetch_requested_at, 11.minutes.ago)
    assert_not post.reload.fetch_requested_recently?
    assert post.claim_fetch_request!
  end

  test "claiming a fetch request does not broadcast a card update" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "see https://x.com/jack/status/102",
      client_message_id: "x-claim-quiet"
    )
    post = message.twitter_posts.first
    post.update_column(:fetch_requested_at, nil) # creating the message claimed once already

    assert_broadcasts room_messages_stream_name(@room), 0 do
      assert post.claim_fetch_request!
    end
  end

  test "creating a message with a post URL references the post and enqueues a fetch" do
    assert_enqueued_with(job: Twitter::FetchPostJob) do
      @message = @room.messages.create!(
        creator: @creator, markdown_source: "look https://x.com/jack/status/120",
        client_message_id: "x-ref-1"
      )
    end

    post = Twitter::Post.find_by(post_id: "120")
    assert post
    assert_equal [ post ], @message.twitter_posts
    assert_equal "https://x.com/jack/status/120", post.url
    # The stored body is untouched: references live in the join table.
    assert_not_includes @message.reload.markdown_source, "x-post-card"
  end

  test "concurrent messages for one post enqueue a single fetch" do
    assert_enqueued_jobs 1, only: Twitter::FetchPostJob do
      @room.messages.create!(
        creator: @creator, markdown_source: "https://x.com/jack/status/103",
        client_message_id: "x-ref-race-1"
      )
      @room.messages.create!(
        creator: @creator, markdown_source: "https://x.com/jack/status/103",
        client_message_id: "x-ref-race-2"
      )
    end
  end

  test "a new reference to a failed post retries the fetch only after ten minutes" do
    post = Twitter::Post.for_reference(post_id: "104", url: "https://x.com/jack/status/104")
    post.update!(fetched_at: 5.minutes.ago, fetch_error: "Post not found on X", fetch_requested_at: 11.minutes.ago)

    assert_no_enqueued_jobs only: Twitter::FetchPostJob do
      @room.messages.create!(
        creator: @creator, markdown_source: "https://x.com/jack/status/104",
        client_message_id: "x-ref-retry-soon"
      )
    end

    post.update!(fetched_at: 11.minutes.ago)

    assert_enqueued_with(job: Twitter::FetchPostJob) do
      @room.messages.create!(
        creator: @creator, markdown_source: "https://x.com/jack/status/104",
        client_message_id: "x-ref-retry-late"
      )
    end
  end

  test "a message without a post URL references nothing and enqueues nothing" do
    assert_no_enqueued_jobs only: Twitter::FetchPostJob do
      message = @room.messages.create!(
        creator: @creator, markdown_source: "just chatting", client_message_id: "x-ref-none"
      )
      assert_empty message.twitter_posts
    end
  end

  test "editing a message to add a post URL adds the reference" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "just chatting", client_message_id: "x-ref-edit"
    )
    assert_empty message.twitter_posts

    assert_enqueued_with(job: Twitter::FetchPostJob) do
      message.update!(markdown_source: "now with https://x.com/jack/status/105")
    end

    assert_equal [ "105" ], message.reload.twitter_posts.map(&:post_id)
  end

  test "editing a message to remove a post URL drops the reference" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "see https://x.com/jack/status/106",
      client_message_id: "x-ref-remove"
    )
    assert_equal 1, message.twitter_post_references.count

    message.update!(markdown_source: "never mind")
    assert_empty message.reload.twitter_posts
  end

  test "updating a record broadcasts a card replace to each referencing room once" do
    other_room = rooms(:watercooler)
    message = @room.messages.create!(
      creator: @creator, markdown_source: "https://x.com/jack/status/107",
      client_message_id: "x-ref-broadcast"
    )
    post = message.twitter_posts.first

    stream = room_messages_stream_name(@room)
    other_stream = room_messages_stream_name(other_room)

    assert_broadcasts stream, 1 do
      assert_broadcasts other_stream, 0 do
        post.update!(text: "just setting up my twttr", fetched_at: Time.current)
      end
    end
  end

  test "card broadcasts target the message container on room and thread streams" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "https://x.com/jack/status/108",
      client_message_id: "x-ref-target-room"
    )
    thread = ChannelThread.create!(room: @room, creator: @creator, name: "X chat")
    thread_message = thread.post_message!(
      creator: @creator,
      attributes: { markdown_source: "https://x.com/jack/status/108", client_message_id: "x-ref-target-thread" }
    )
    post = message.twitter_posts.first
    assert_equal [ post ], thread_message.twitter_posts

    room_broadcasts = capture_broadcasts(room_messages_stream_name(@room)) do
      capture_broadcasts(thread_messages_stream_name(thread)) do
        post.update!(text: "just setting up my twttr", fetched_at: Time.current)
      end
    end

    assert_equal 1, room_broadcasts.size
    assert_includes room_broadcasts.first.to_s, ActionView::RecordIdentifier.dom_id(message, :twitter_cards)
    assert_includes room_broadcasts.first.to_s, "just setting up my twttr"

    thread_broadcasts = capture_broadcasts(thread_messages_stream_name(thread)) do
      post.update!(author_name: "jack")
    end
    assert_equal 1, thread_broadcasts.size
    assert_includes thread_broadcasts.first.to_s, ActionView::RecordIdentifier.dom_id(thread_message, :twitter_cards)
  end

  private
    def room_messages_stream_name(room)
      signed = Turbo::StreamsChannel.signed_stream_name([ room, :messages ])
      Turbo::StreamsChannel.verified_stream_name(signed)
    end

    def thread_messages_stream_name(thread)
      signed = Turbo::StreamsChannel.signed_stream_name([ thread, :messages ])
      Turbo::StreamsChannel.verified_stream_name(signed)
    end
end
