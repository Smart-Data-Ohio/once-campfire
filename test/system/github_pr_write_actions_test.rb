require "application_system_test_case"

class GithubPrWriteActionsTest < ApplicationSystemTestCase
  setup do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  teardown do
    WebMock.reset!
    WebMock.disable!
  end

  test "a linked member comments from a PR thread and sees the inline confirmation" do
    room = rooms(:designers)
    user = users(:jz)
    GithubConnectedAccount.create!(user:, github_login: "jz", access_token: "user-token-system")

    message = room.messages.create!(
      creator: user,
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "system-write-comment"
    )
    pull_request = message.github_pull_requests.first
    pull_request.update!(
      private: false,
      title: "Fix login", author_login: "alice", state: "open",
      base_branch: "main", head_branch: "shiny",
      review_decision: "approved", check_status: "passing",
      html_url: "https://github.com/rails/rails/pull/12",
      github_updated_at: 1.hour.ago, fetched_at: Time.current, fetch_error: nil
    )
    pull_request.update_column(:fetch_requested_at, nil)

    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .with(
        body: { body: "Ship it" }.to_json,
        headers: { "Authorization" => "Bearer user-token-system" }
      )
      .to_return(status: 201, body: { id: 1 }.to_json)

    sign_in "jz@37signals.com"
    join_room room
    within(:css, ".github-pr-card", text: "Fix login", wait: 10) do
      click_button "Discuss"
    end

    assert_selector ".github-pr-thread-header .github-pr-card__title", text: "Fix login", wait: 10

    within(:css, ".github-pr-write", wait: 10) do
      fill_in "Comment on GitHub", with: "Ship it"
      click_button "Comment on GitHub"
    end

    assert_selector ".github-pr-write__notice", text: "Comment posted on GitHub as @jz", wait: 10
    assert_field "Comment on GitHub", with: ""
    assert_requested stub
  end

  test "a linked member requests a review from a PR thread and sees the inline confirmation" do
    room = rooms(:designers)
    user = users(:jz)
    GithubConnectedAccount.create!(user:, github_login: "jz", access_token: "user-token-system")

    message = room.messages.create!(
      creator: user,
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "system-write-review-request"
    )
    pull_request = message.github_pull_requests.first
    pull_request.update!(
      private: false,
      title: "Fix login", author_login: "alice", state: "open",
      base_branch: "main", head_branch: "shiny",
      review_decision: "approved", check_status: "passing",
      html_url: "https://github.com/rails/rails/pull/12",
      github_updated_at: 1.hour.ago, fetched_at: Time.current, fetch_error: nil
    )
    pull_request.update_column(:fetch_requested_at, nil)

    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .with(
        body: { reviewers: [ "alice", "bob" ] }.to_json,
        headers: { "Authorization" => "Bearer user-token-system" }
      )
      .to_return(status: 201, body: { id: 12 }.to_json)

    sign_in "jz@37signals.com"
    join_room room
    within(:css, ".github-pr-card", text: "Fix login", wait: 10) do
      click_button "Discuss"
    end

    assert_selector ".github-pr-thread-header .github-pr-card__title", text: "Fix login", wait: 10

    within(:css, ".github-pr-write", wait: 10) do
      fill_in "GitHub usernames", with: "alice, bob"
      click_button "Request review"
    end

    assert_selector ".github-pr-write__notice", text: "Requested review from @alice, @bob on GitHub as @jz", wait: 10
    assert_field "GitHub usernames", with: ""
    assert_requested stub
  end

  test "a member without a linked token sees the connect prompt in the thread" do
    room = rooms(:designers)
    user = users(:jz)

    message = room.messages.create!(
      creator: user,
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "system-write-connect-prompt"
    )
    pull_request = message.github_pull_requests.first
    pull_request.update!(
      private: false,
      title: "Fix login", author_login: "alice", state: "open",
      base_branch: "main", head_branch: "shiny",
      html_url: "https://github.com/rails/rails/pull/12",
      github_updated_at: 1.hour.ago, fetched_at: Time.current, fetch_error: nil
    )
    pull_request.update_column(:fetch_requested_at, nil)

    sign_in "jz@37signals.com"
    join_room room
    within(:css, ".github-pr-card", text: "Fix login", wait: 10) do
      click_button "Discuss"
    end

    assert_selector ".github-pr-thread-header .github-pr-card__title", text: "Fix login", wait: 10
    assert_selector ".github-pr-write__connect", text: /Connect GitHub/, wait: 10
    assert_no_selector ".github-pr-write__comment"
  end
end
