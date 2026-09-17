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

  test "request_reviewers posts the logins to the requested_reviewers endpoint" do
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .with(
        body: { reviewers: [ "alice", "bob" ] }.to_json,
        headers: { "Authorization" => "Bearer user-token-123" }
      )
      .to_return(status: 201, body: { id: 12 }.to_json)

    assert_equal({ "id" => 12 }, @client.request_reviewers(@pull_request, logins: [ "alice", "bob" ]))
    assert_requested stub
  end

  test "request_reviewers maps a GitHub 422 to Refused with GitHub's message" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .to_return(status: 422, body: { message: "Review cannot be requested from pull request author" }.to_json)

    error = assert_raises(Github::WriteClient::Refused) do
      @client.request_reviewers(@pull_request, logins: [ "alice" ])
    end
    assert_equal "GitHub refused: Review cannot be requested from pull request author", error.message
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

    log = StringIO.new
    with_swapped_logger(log) do
      error = assert_raises(Github::WriteClient::Error) do
        @client.create_issue_comment(@pull_request, body: "hi")
      end
      assert_match(/Could not reach GitHub/, error.message)
    end

    assert_includes log.string, "Github::WriteClient request failed"
    assert_not_includes log.string, "user-token-123"
  end

  test "repository_readable? is true when GitHub answers 200" do
    client = Github::WriteClient.new(token: "viewer-token")
    stub = stub_request(:get, "https://api.github.com/repos/rails/rails")
      .with(headers: { "Authorization" => "Bearer viewer-token" })
      .to_return(status: 200, body: { private: true }.to_json)

    assert client.repository_readable?("rails", "rails")
    assert_requested stub
  end

  test "repository_readable? is false on 403 and 404" do
    stub_request(:get, "https://api.github.com/repos/rails/rails")
      .to_return(status: 403, body: { message: "Resource not accessible by personal access token" }.to_json)

    assert_not @client.repository_readable?("rails", "rails")

    stub_request(:get, "https://api.github.com/repos/rails/rails")
      .to_return(status: 404, body: { message: "Not Found" }.to_json)

    assert_not @client.repository_readable?("rails", "rails")
  end

  test "repository_readable? raises Unauthorized on 401" do
    stub_request(:get, "https://api.github.com/repos/rails/rails")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json)

    assert_raises(Github::WriteClient::Unauthorized) do
      @client.repository_readable?("rails", "rails")
    end
  end

  test "repository_readable? raises Error on network failure" do
    stub_request(:get, "https://api.github.com/repos/rails/rails").to_timeout

    error = assert_raises(Github::WriteClient::Error) do
      @client.repository_readable?("rails", "rails")
    end
    assert_match(/Could not reach GitHub/, error.message)
  end

  private
    def with_swapped_logger(io)
      capture = ActiveSupport::TaggedLogging.new(Logger.new(io))
      original_logger = Rails.logger
      Rails.logger = capture
      yield
    ensure
      Rails.logger = original_logger
    end
end
