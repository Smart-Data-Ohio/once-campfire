require "test_helper"

class GithubPullRequestsHelperTest < ActionView::TestCase
  include Github::PullRequestsHelper

  test "cache key changes when a referenced pull request is updated" do
    message = messages(:first)
    pull_request = Github::PullRequest.create!(owner: "smart-data-ohio", repo: "smartfire", number: 42)
    Github::PullRequestReference.create!(message:, pull_request:)
    message.reload

    before = message_with_pr_cards_cache_key(message)
    travel 1.minute do
      pull_request.update!(title: "Updated title")
    end

    assert_not_equal before, message_with_pr_cards_cache_key(message.reload)
  end

  test "cache key for a message without pull requests is just the message" do
    assert_equal [ messages(:first), nil ], message_with_pr_cards_cache_key(messages(:first))
  end

  test "cache key changes when a referenced X post is fetched" do
    message = messages(:first)
    post = Twitter::Post.create!(post_id: "500", url: "https://x.com/jack/status/500")
    Twitter::PostReference.create!(message:, post:)
    message.reload

    before = message_with_pr_cards_cache_key(message)
    travel 1.minute do
      post.update!(text: "just setting up my twttr", fetched_at: Time.current)
    end

    assert_not_equal before, message_with_pr_cards_cache_key(message.reload)
  end

  test "cache key changes when a referenced event is updated" do
    message = messages(:first)
    event = events(:launch_party)
    EventReference.create!(message:, event:)
    message.reload

    before = message_with_pr_cards_cache_key(message)
    travel 1.minute do
      event.update!(title: "Updated title")
    end

    assert_not_equal before, message_with_pr_cards_cache_key(message.reload)
  end
end
