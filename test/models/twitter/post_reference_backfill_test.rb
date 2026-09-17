require "test_helper"

class Twitter::PostReferenceBackfillTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionDispatch::TestProcess

  setup do
    @room = rooms(:designers)
    @creator = users(:david)
  end

  test "syncs references for Markdown and legacy messages with post URLs" do
    markdown_message = @room.messages.create!(
      creator: @creator, markdown_source: "look https://x.com/jack/status/301",
      client_message_id: "x-backfill-markdown"
    )
    legacy_message = @room.messages.create!(
      creator: @creator, client_message_id: "x-backfill-legacy",
      body: "<div>Look at this: https://x.com/jack/status/302</div>"
    )
    plain_message = @room.messages.create!(
      creator: @creator, markdown_source: "just chatting",
      client_message_id: "x-backfill-plain"
    )
    # Simulate messages the sync never reached: no references, no post rows.
    [ markdown_message, legacy_message ].each do |message|
      message.twitter_post_references.delete_all
    end
    Twitter::Post.where(post_id: %w[ 301 302 ]).delete_all
    clear_enqueued_jobs

    synced = nil
    assert_enqueued_jobs 2, only: Twitter::FetchPostJob do
      synced = Twitter::PostReferenceBackfill.call
    end

    # The x_card_post fixture also carries a post URL, so three match.
    assert_equal 3, synced
    assert_equal [ "301" ], markdown_message.reload.twitter_posts.map(&:post_id)
    assert_equal [ "302" ], legacy_message.reload.twitter_posts.map(&:post_id)
    assert_empty plain_message.reload.twitter_posts
  end

  test "is idempotent and enqueues each fetch once" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "look https://x.com/jack/status/303",
      client_message_id: "x-backfill-idempotent"
    )
    message.twitter_post_references.delete_all
    Twitter::Post.where(post_id: "303").delete_all
    clear_enqueued_jobs

    first_synced = nil
    assert_enqueued_jobs 1, only: Twitter::FetchPostJob do
      first_synced = Twitter::PostReferenceBackfill.call
    end
    references = Twitter::PostReference.count

    second_synced = nil
    assert_no_enqueued_jobs only: Twitter::FetchPostJob do
      second_synced = Twitter::PostReferenceBackfill.call
    end

    # The x_card_post fixture also carries a post URL, so two match each run.
    assert_equal 2, first_synced
    assert_equal 2, second_synced
    assert_equal references, Twitter::PostReference.count
    assert_equal [ "303" ], message.reload.twitter_posts.map(&:post_id)
  end

  test "tolerates a message without rich text" do
    message = @room.messages.create_with_attachment!(
      creator: @creator, client_message_id: "x-backfill-bare",
      attachment: fixture_file_upload("moon.jpg", "image/jpeg")
    )

    Twitter::PostReferenceBackfill.call

    assert_empty message.reload.twitter_posts
  end
end
