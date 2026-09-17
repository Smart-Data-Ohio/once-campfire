require "test_helper"

class TwitterPostsHelperTest < ActionView::TestCase
  include Twitter::PostsHelper

  test "compact_count renders compact K/M/B units" do
    assert_equal "999", compact_count(999)
    assert_equal "18K", compact_count(18041)
    assert_equal "125K", compact_count(124658)
    assert_equal "311K", compact_count(310826)
    assert_equal "1.2M", compact_count(1_200_000)
  end

  test "twitter_post_cards_for sorts by numeric post id" do
    message = rooms(:designers).messages.create!(
      creator: users(:david),
      markdown_source: "https://x.com/jack/status/502 https://x.com/jack/status/99",
      client_message_id: "x-cards-order"
    )

    assert_equal %w[ 99 502 ], twitter_post_cards_for(message.reload).map(&:post_id)
  end

  test "twitter_post_cards_for enqueues a fetch for a never-fetched post once" do
    message = rooms(:designers).messages.create!(
      creator: users(:david), markdown_source: "see https://x.com/jack/status/503",
      client_message_id: "x-cards-reclaim"
    )
    post = message.twitter_posts.first
    post.update_column(:fetch_requested_at, nil) # the sync already claimed once
    clear_enqueued_jobs

    assert_enqueued_jobs 1, only: Twitter::FetchPostJob do
      twitter_post_cards_for(message.reload)
    end
    assert_predicate post.reload, :fetch_requested_recently?

    assert_no_enqueued_jobs only: Twitter::FetchPostJob do
      twitter_post_cards_for(message.reload)
    end
  end

  test "twitter_post_cards_for does not enqueue for fetched or failed posts" do
    Twitter::Post.create!(post_id: "504", url: "https://x.com/jack/status/504",
      fetched_at: 1.hour.ago, fetch_error: nil)
    Twitter::Post.create!(post_id: "505", url: "https://x.com/jack/status/505",
      fetched_at: 1.hour.ago, fetch_error: "Post not found on X")
    message = rooms(:designers).messages.create!(
      creator: users(:david),
      markdown_source: "https://x.com/jack/status/504 https://x.com/jack/status/505",
      client_message_id: "x-cards-no-reclaim"
    )
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: Twitter::FetchPostJob do
      assert_equal %w[ 504 505 ], twitter_post_cards_for(message.reload).map(&:post_id)
    end
  end

  test "twitter_post_exists? reports the row and memoizes per post" do
    assert twitter_post_exists?("20")
    assert_not twitter_post_exists?("999999")

    # The query cache is off, so every unmemoized lookup costs a query.
    repeat_lookups = count_queries do
      2.times { twitter_post_exists?("20") }
      2.times { twitter_post_exists?("999999") }
    end
    assert_equal 0, repeat_lookups
  end

  test "twitter_x_logo_tag renders the registry X icon" do
    icon = Icons.find("x")
    assert_not_nil icon, "expected an X brand icon in the registry"

    tag = twitter_x_logo_tag
    assert_includes tag, Icons.image_url_for(icon)
    assert_includes tag, "x-post-card__logo"
  end

  private
    def count_queries(&block)
      queries = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA"
      end

      ActiveRecord::Base.uncached(&block)
      queries.size
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
end
