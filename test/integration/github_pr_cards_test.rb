require "test_helper"

class GithubPrCardsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
  end

  test "a message with a PR link renders the card" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "please review https://github.com/rails/rails/pull/123",
      client_message_id: "card-render-1"
    )
    fill_card(message.github_pull_requests.first)

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card", count: 1
    assert_select ".github-pr-card__repo", text: "rails/rails"
    assert_select ".github-pr-card__number", text: "#123"
    assert_select ".github-pr-card__title", text: "Add shiny things"
    assert_select ".github-pr-card__author", text: /dhh/
    assert_select ".github-pr-card__state", text: "Open"
    assert_select ".github-pr-card__branches", text: /main ← shiny/
    assert_select ".github-pr-card__review", text: "Approved"
    assert_select ".github-pr-card__checks", text: "Checks passing"
    assert_select '.github-pr-card__link[href="https://github.com/rails/rails/pull/123"]'
    assert_select '.github-pr-card__link[rel="noopener noreferrer"]', count: 1
  end

  test "the card keeps the fetched repository name case" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "please review https://github.com/Rails/Rails/pull/124",
      client_message_id: "card-render-case"
    )
    pull_request = message.github_pull_requests.first
    fill_card(pull_request)
    pull_request.update!(
      html_url: "https://github.com/Rails/Rails/pull/124",
      payload: { "base" => { "repo" => { "full_name" => "Rails/Rails" } } }
    )

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card__repo", text: "Rails/Rails"
  end

  test "a message without a PR link renders no card" do
    @room.messages.create!(
      creator: users(:david), markdown_source: "just chatting", client_message_id: "card-render-none"
    )

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card", count: 0
  end

  test "an unfetched public PR renders a loading card" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "https://github.com/rails/rails/pull/124",
      client_message_id: "card-render-loading"
    )
    message.github_pull_requests.first.update!(private: false)

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card__loading", text: /Loading pull request/
  end

  test "a failed fetch renders an error card" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "https://github.com/rails/rails/pull/125",
      client_message_id: "card-render-error"
    )
    message.github_pull_requests.first.update!(
      private: false, fetched_at: Time.current, fetch_error: "Pull request not found on GitHub")

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card__error", text: /couldn.t load/i
  end

  test "a private PR renders only the empty lazy frame in the message HTML" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "please review https://github.com/acme/secret/pull/123",
      client_message_id: "card-render-private"
    )
    pull_request = message.github_pull_requests.first
    fill_card(pull_request, is_private: true)

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card", count: 0
    assert_select "turbo-frame.github-pr-card-frame[loading=lazy][src=?]",
      room_github_pull_request_card_path(@room, pull_request, message_id: message.id), count: 1
    assert_not_includes response.body, "Add shiny things"
  end

  test "a PR with unknown privacy is treated as private" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "please review https://github.com/acme/secret/pull/124",
      client_message_id: "card-render-unknown"
    )
    pull_request = message.github_pull_requests.first
    fill_card(pull_request, is_private: nil)

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card", count: 0
    assert_select "turbo-frame.github-pr-card-frame[loading=lazy]", count: 1
    assert_not_includes response.body, "Add shiny things"
  end

  test "rendering a stale card enqueues a refresh" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "https://github.com/rails/rails/pull/126",
      client_message_id: "card-render-stale"
    )
    fill_card(message.github_pull_requests.first, fetched_at: 11.minutes.ago)

    assert_enqueued_with(job: Github::FetchPullRequestJob) do
      get room_url(@room)
    end

    assert_response :success
  end

  test "a loaded card with no check data shows No checks" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "https://github.com/rails/rails/pull/131",
      client_message_id: "card-render-no-checks"
    )
    fill_card(message.github_pull_requests.first, check_status: nil)

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card__checks", text: "No checks"
  end

  test "rendering a room page costs no extra queries per message with a PR link" do
    create_pr_messages(2, offset: 200)

    # Warm per-process caches (the workspace icon registry's version stamp)
    # so the two measured renders share the same constant cold-cache cost.
    get room_url(@room)
    assert_response :success

    small = count_queries { get room_url(@room) }
    assert_response :success

    create_pr_messages(4, offset: 300)
    large = count_queries { get room_url(@room) }
    assert_response :success

    assert_equal small, large,
      "room render should be O(1) in queries, got #{small} then #{large}"
  end

  test "one render enqueues a single refresh for one stale PR linked by many messages" do
    3.times do |i|
      @room.messages.create!(
        creator: users(:david),
        markdown_source: "see https://github.com/rails/rails/pull/129",
        client_message_id: "card-dedupe-#{i}"
      )
    end
    pull_request = Github::PullRequest.find_by!(owner: "rails", repo: "rails", number: 129)
    fill_card(pull_request, fetched_at: 11.minutes.ago)

    assert_enqueued_jobs 1, only: Github::FetchPullRequestJob do
      get room_url(@room)
    end

    assert_response :success
  end

  test "repeat views by different users enqueue at most one refresh per PR per window" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "https://github.com/rails/rails/pull/130",
      client_message_id: "card-window-1"
    )
    fill_card(message.github_pull_requests.first, fetched_at: 11.minutes.ago)

    assert_enqueued_jobs 1, only: Github::FetchPullRequestJob do
      get room_url(@room)
    end
    assert_response :success

    delete session_url
    sign_in :jason # another designers member

    assert_no_enqueued_jobs only: Github::FetchPullRequestJob do
      get room_url(@room)
    end
    assert_response :success
  end

  test "a fresh card does not enqueue a refresh on render" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "https://github.com/rails/rails/pull/127",
      client_message_id: "card-render-fresh"
    )
    fill_card(message.github_pull_requests.first, fetched_at: 1.minute.ago)

    assert_no_enqueued_jobs only: Github::FetchPullRequestJob do
      get room_url(@room)
    end

    assert_response :success
  end

  test "a non-member cannot see the card through the room" do
    room = rooms(:pets) # kevin is not a member
    message = room.messages.create!(
      creator: users(:david),
      markdown_source: "https://github.com/rails/rails/pull/128",
      client_message_id: "card-render-private"
    )
    fill_card(message.github_pull_requests.first)

    delete session_url
    sign_in :kevin

    get room_url(room)

    assert_redirected_to root_url
    follow_redirect!
    assert_select ".github-pr-card", count: 0
  end

  test "added routes never render card content to unauthorized callers" do
    # The only route this slice adds is the webhook receiver. It authenticates
    # via HMAC, never renders cards, and rejects unsigned calls.
    original_secret = ENV["GITHUB_WEBHOOK_SECRET"]
    ENV["GITHUB_WEBHOOK_SECRET"] = "webhook-secret"

    post github_webhooks_url, params: {}.to_json, headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
    assert_not_includes response.body, "github-pr-card"
  ensure
    ENV["GITHUB_WEBHOOK_SECRET"] = original_secret
  end

  private
    def fill_card(pull_request, fetched_at: Time.current, check_status: "passing", is_private: false)
      pull_request.update!(
        private: is_private,
        title: "Add shiny things", author_login: "dhh",
        author_avatar_url: "https://avatars.example/dhh",
        state: "open", base_branch: "main", head_branch: "shiny", head_sha: "abc123",
        review_decision: "approved", check_status: check_status,
        html_url: "https://github.com/rails/rails/pull/123",
        github_updated_at: 1.hour.ago, payload: {}, fetched_at: fetched_at, fetch_error: nil
      )
      # The broadcast above re-renders the card, which would otherwise claim
      # the fetch request: every render test starts unrequested.
      pull_request.update_column(:fetch_requested_at, nil)
    end

    def create_pr_messages(count, offset:)
      count.times do |i|
        number = offset + i
        message = @room.messages.create!(
          creator: users(:david),
          markdown_source: "review https://github.com/rails/rails/pull/#{number}",
          client_message_id: "card-query-#{number}"
        )
        fill_card(message.github_pull_requests.first, fetched_at: 1.minute.ago)
      end
    end

    # Same shape as the count_queries in Message::RenderingDetailsTest: every
    # SQL statement except schema loads and query-cache hits.
    def count_queries
      count = 0
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
      end

      ActiveRecord::Base.connection.clear_query_cache
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
end
