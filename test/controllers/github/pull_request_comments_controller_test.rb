require "test_helper"

class Github::PullRequestCommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
    @message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "write-comment-1"
    )
    @pull_request = @message.github_pull_requests.first
    @thread = ChannelThread.create!(room: @room, creator: users(:david), parent_message: @message)
    ThreadMembership.join!(@thread, users(:david))
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: @thread)

    @original_token = ENV["GITHUB_TOKEN"]
    ENV["GITHUB_TOKEN"] = "workspace-token"
  end

  teardown do
    ENV["GITHUB_TOKEN"] = @original_token
  end

  test "posts the comment with the member's token, never the workspace token" do
    link_github!(users(:david), token: "user-token-abc")
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .with(body: { body: "Nice work" }.to_json)
      .to_return(status: 201, body: { id: 1 }.to_json)

    assert_no_difference -> { Message.count } do
      post room_github_pull_request_comments_url(@room),
        params: { pull_request_id: @pull_request.id, body: "Nice work" }
    end

    assert_response :success
    assert_requested stub, headers: { "Authorization" => "Bearer user-token-abc" }
    assert_select "turbo-frame##{write_actions_dom_id}" do
      assert_select ".github-pr-write__notice", text: "Comment posted on GitHub as @david."
      assert_select "form[action=?]", room_github_pull_request_comments_path(@room) do
        assert_select "textarea[name=body]", text: ""
      end
    end
  end

  test "success over Turbo Stream replaces the frame with the confirmation" do
    link_github!(users(:david))
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 201, body: { id: 1 }.to_json)

    post room_github_pull_request_comments_url(@room),
      headers: { "Accept" => "text/vnd.turbo-stream.html" },
      params: { pull_request_id: @pull_request.id, body: "Nice work" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, write_actions_dom_id
    assert_includes response.body, "Comment posted on GitHub"
  end

  test "non-members get not found" do
    sign_in :kevin # not a member of the watercooler
    room = rooms(:watercooler)

    assert_raises(ActiveRecord::RecordNotFound) do
      post room_github_pull_request_comments_url(room),
        params: { pull_request_id: @pull_request.id, body: "hi" }
    end
  end

  test "a member without a linked token gets the connect prompt" do
    post room_github_pull_request_comments_url(@room),
      params: { pull_request_id: @pull_request.id, body: "Nice work" }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__connect a[href=?]", user_profile_path, text: "Connect GitHub"
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "a member with a disconnected token gets the reconnect prompt" do
    account = link_github!(users(:david))
    account.mark_disconnected!("GitHub rejected the linked token (401)")

    post room_github_pull_request_comments_url(@room),
      params: { pull_request_id: @pull_request.id, body: "Nice work" }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__connect", text: /Reconnect GitHub/
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "a GitHub 403 renders inline with no retry" do
    link_github!(users(:david))
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 403, body: { message: "Resource not accessible by personal access token" }.to_json)

    post room_github_pull_request_comments_url(@room),
      headers: { "Accept" => "text/vnd.turbo-stream.html" },
      params: { pull_request_id: @pull_request.id, body: "Nice work" }

    assert_response :unprocessable_content
    assert_includes response.body, "GitHub refused: Resource not accessible by personal access token"
    assert_requested stub, times: 1
  end

  test "a GitHub 401 disconnects the account and shows the reconnect prompt" do
    account = link_github!(users(:david))
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json)

    post room_github_pull_request_comments_url(@room),
      params: { pull_request_id: @pull_request.id, body: "Nice work" }

    assert_response :unprocessable_content
    assert_not_predicate account.reload, :usable?
    assert_equal "GitHub rejected the linked token (401)", account.disconnected_reason
    assert_select ".github-pr-write__error", text: /GitHub rejected your token/
    assert_select ".github-pr-write__connect", text: /Reconnect GitHub/
  end

  test "a blank body is rejected without calling GitHub" do
    link_github!(users(:david))

    post room_github_pull_request_comments_url(@room),
      params: { pull_request_id: @pull_request.id, body: "  " }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__error", text: "Write a comment first."
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "a PR the room does not discuss gets not found" do
    link_github!(users(:david))
    other_pr = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 13)

    assert_raises(ActiveRecord::RecordNotFound) do
      post room_github_pull_request_comments_url(@room),
        params: { pull_request_id: other_pr.id, body: "hi" }
    end
  end

  test "posting never logs the member's token" do
    link_github!(users(:david), token: "user-token-secret-xyz")
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 201, body: { id: 1 }.to_json)

    log = StringIO.new
    with_captured_logs(log) do
      post room_github_pull_request_comments_url(@room),
        params: { pull_request_id: @pull_request.id, body: "Nice work" }
    end

    assert_response :success
    assert_includes log.string, "pull_request_comments"
    assert_not_includes log.string, "user-token-secret-xyz"
  end

  private
    def link_github!(user, token: "user-token-abc")
      GithubConnectedAccount.create!(user:, github_login: user.name.parameterize, access_token: token)
    end

    def write_actions_dom_id
      ActionView::RecordIdentifier.dom_id(@thread, :github_write_actions)
    end

    def with_captured_logs(io)
      capture = ActiveSupport::TaggedLogging.new(Logger.new(io))
      original_rails_logger = Rails.logger
      original_subscriber_logger = ActiveSupport::LogSubscriber.logger

      Rails.logger = capture
      ActiveSupport::LogSubscriber.logger = capture
      yield
    ensure
      Rails.logger = original_rails_logger
      ActiveSupport::LogSubscriber.logger = original_subscriber_logger
    end
end
