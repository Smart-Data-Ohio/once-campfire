require "test_helper"

class Github::PullRequestWriteActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
    @message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "write-actions-1"
    )
    @pull_request = @message.github_pull_requests.first
    @thread = ChannelThread.create!(room: @room, creator: users(:david), parent_message: @message)
    ThreadMembership.join!(@thread, users(:david))
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: @thread)
  end

  test "a linked member gets the composer and review buttons" do
    GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "x")

    get room_github_pull_request_write_action_url(@room, @pull_request)

    assert_response :success
    assert_select "form[action=?]", room_github_pull_request_comments_path(@room) do
      assert_select "textarea[name=body]"
      assert_select "input[type=submit][value=?]", "Comment on GitHub"
    end
    assert_select "form[action=?]", room_github_pull_request_reviews_path(@room) do
      assert_select "button[name=event][value=APPROVE]", text: "Approve"
      assert_select "button[name=event][value=REQUEST_CHANGES]", text: "Request changes"
    end
    assert_select ".github-pr-write__connect", count: 0
  end

  test "a member without a linked token gets the connect prompt" do
    get room_github_pull_request_write_action_url(@room, @pull_request)

    assert_response :success
    assert_select ".github-pr-write__connect a[href=?]", user_profile_path, text: "Connect GitHub"
    assert_select "form[action=?]", room_github_pull_request_comments_path(@room), count: 0
  end

  test "a member with a disconnected token gets the reconnect prompt" do
    account = GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "x")
    account.mark_disconnected!("GitHub rejected the linked token (401)")

    get room_github_pull_request_write_action_url(@room, @pull_request)

    assert_response :success
    assert_select ".github-pr-write__connect", text: /Reconnect GitHub/
    assert_select "form[action=?]", room_github_pull_request_comments_path(@room), count: 0
  end

  test "non-members get not found" do
    sign_in :kevin # not a member of the watercooler

    assert_raises(ActiveRecord::RecordNotFound) do
      get room_github_pull_request_write_action_url(rooms(:watercooler), @pull_request)
    end
  end

  test "the thread header carries the write-actions frame" do
    GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "x")

    get room_thread_url(@room, @thread)

    assert_response :success
    frame_id = ActionView::RecordIdentifier.dom_id(@thread, :github_write_actions)
    assert_select ".github-pr-thread-header turbo-frame##{frame_id}[src=?]",
      room_github_pull_request_write_action_path(@room, @pull_request)
  end
end
