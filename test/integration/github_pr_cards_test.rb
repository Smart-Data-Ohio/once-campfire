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
  end

  test "a message without a PR link renders no card" do
    @room.messages.create!(
      creator: users(:david), markdown_source: "just chatting", client_message_id: "card-render-none"
    )

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card", count: 0
  end

  test "an unfetched PR renders a loading card" do
    @room.messages.create!(
      creator: users(:david),
      markdown_source: "https://github.com/rails/rails/pull/124",
      client_message_id: "card-render-loading"
    )

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
    message.github_pull_requests.first.update!(fetched_at: Time.current, fetch_error: "Pull request not found on GitHub")

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card__error", text: /couldn.t load/i
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
    def fill_card(pull_request, fetched_at: Time.current)
      pull_request.update!(
        title: "Add shiny things", author_login: "dhh",
        author_avatar_url: "https://avatars.example/dhh",
        state: "open", base_branch: "main", head_branch: "shiny", head_sha: "abc123",
        review_decision: "approved", check_status: "passing",
        html_url: "https://github.com/rails/rails/pull/123",
        github_updated_at: 1.hour.ago, payload: {}, fetched_at: fetched_at, fetch_error: nil
      )
    end
end
