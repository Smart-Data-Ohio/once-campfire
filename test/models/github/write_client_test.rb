require "test_helper"

class Github::WriteClientTest < ActiveSupport::TestCase
  setup do
    @pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    @client = Github::WriteClient.new(token: "user-token-123")
  end

  test "authenticated_login returns the token owner's login" do
    stub_request(:get, "https://api.github.com/user")
      .with(headers: { "Authorization" => "Bearer user-token-123" })
      .to_return(status: 200, body: { login: "octocat" }.to_json)

    assert_equal "octocat", Github::WriteClient.authenticated_login("user-token-123")
  end

  test "authenticated_login raises Unauthorized on 401" do
    stub_request(:get, "https://api.github.com/user").to_return(status: 401, body: {}.to_json)

    assert_raises(Github::WriteClient::Unauthorized) do
      Github::WriteClient.authenticated_login("bad-token")
    end
  end

  test "create_issue_comment posts to the issues comments endpoint" do
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .with(
        body: { body: "Looks good" }.to_json,
        headers: { "Authorization" => "Bearer user-token-123" }
      )
      .to_return(status: 201, body: { id: 1 }.to_json)

    assert_equal({ "id" => 1 }, @client.create_issue_comment(@pull_request, body: "Looks good"))
    assert_requested stub
  end

  test "create_review posts approve and request-changes events" do
    approve = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/reviews")
      .with(body: { event: "APPROVE" }.to_json)
      .to_return(status: 200, body: { id: 2 }.to_json)

    @client.create_review(@pull_request, event: "APPROVE")

    changes = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/reviews")
      .with(body: { event: "REQUEST_CHANGES", body: "Fix this" }.to_json)
      .to_return(status: 200, body: { id: 3 }.to_json)

    @client.create_review(@pull_request, event: "REQUEST_CHANGES", body: "Fix this")

    assert_requested approve
    assert_requested changes
  end

  test "401 raises Unauthorized" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json)

    assert_raises(Github::WriteClient::Unauthorized) do
      @client.create_issue_comment(@pull_request, body: "hi")
    end
  end

  test "403 and 404 raise Refused with GitHub's message" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 403, body: { message: "Resource not accessible by personal access token" }.to_json)
    stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/reviews")
      .to_return(status: 404, body: { message: "Not Found" }.to_json)

    error = assert_raises(Github::WriteClient::Refused) do
      @client.create_issue_comment(@pull_request, body: "hi")
    end
    assert_equal "GitHub refused: Resource not accessible by personal access token", error.message

    error = assert_raises(Github::WriteClient::Refused) do
      @client.create_review(@pull_request, event: "APPROVE")
    end
    assert_equal "GitHub refused: Not Found", error.message
  end

  test "network errors raise Error without logging the token" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments").to_timeout

    error = assert_raises(Github::WriteClient::Error) do
      with_captured_logs { @client.create_issue_comment(@pull_request, body: "hi") }
    end

    assert_match(/Could not reach GitHub/, error.message)
  end

  private
    def with_captured_logs(&block)
      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log)
      block.call
      assert_no_includes log.string, "user-token-123"
    ensure
      Rails.logger = original_logger
    end
end
