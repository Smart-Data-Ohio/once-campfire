require "test_helper"

class Github::FetchPullRequestJobTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @original_token = ENV["GITHUB_TOKEN"]
    ENV["GITHUB_TOKEN"] = "test-token"
    @pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 123)
  end

  teardown do
    ENV["GITHUB_TOKEN"] = @original_token
  end

  test "success stores card fields, clears errors, and stamps fetched_at" do
    stub_pull_request(state: "open", draft: false)
    stub_reviews([ { "state" => "APPROVED", "submitted_at" => "2026-09-02T00:00:00Z", "user" => { "id" => 1 } } ])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)

    @pull_request.reload
    assert_equal "Add shiny things", @pull_request.title
    assert_equal "dhh", @pull_request.author_login
    assert_equal "open", @pull_request.state
    assert_equal "main", @pull_request.base_branch
    assert_equal "shiny", @pull_request.head_branch
    assert_equal "approved", @pull_request.review_decision
    assert_equal "passing", @pull_request.check_status
    assert_equal "https://github.com/rails/rails/pull/123", @pull_request.html_url
    assert_not_nil @pull_request.github_updated_at
    assert_not_nil @pull_request.payload
    assert_not_nil @pull_request.fetched_at
    assert_nil @pull_request.fetch_error
  end

  test "merged, closed, and draft states map to card states" do
    stub_pull_request(state: "closed", merged_at: "2026-09-01T00:00:00Z")
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)
    assert_equal "merged", @pull_request.reload.state
  end

  test "changes requested wins over approvals" do
    stub_pull_request(state: "open", draft: false)
    stub_reviews([
      { "state" => "APPROVED", "submitted_at" => "2026-09-02T00:00:00Z", "user" => { "id" => 1 } },
      { "state" => "CHANGES_REQUESTED", "submitted_at" => "2026-09-03T00:00:00Z", "user" => { "id" => 2 } }
    ])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)
    assert_equal "changes_requested", @pull_request.reload.review_decision
  end

  test "failing check runs map to failing" do
    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([ { "status" => "completed", "conclusion" => "failure" } ])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)
    assert_equal "failing", @pull_request.reload.check_status
  end

  test "404 leaves a fetch_error and stamps fetched_at without raising" do
    WebMock.stub_request(:get, %r{\Ahttps://api\.github\.com/repos/rails/rails/pulls/123\z})
      .to_return(status: 404, body: { message: "Not Found" }.to_json)

    Github::FetchPullRequestJob.perform_now(@pull_request)

    @pull_request.reload
    assert_equal "Pull request not found on GitHub", @pull_request.fetch_error
    assert_not_nil @pull_request.fetched_at
  end

  test "rate limiting leaves a fetch_error without raising" do
    WebMock.stub_request(:get, %r{\Ahttps://api\.github\.com/repos/rails/rails/pulls/123\z})
      .to_return(status: 403, body: { message: "rate limited" }.to_json,
        headers: { "X-RateLimit-Remaining" => "0", "X-RateLimit-Reset" => "9999999999" })

    Github::FetchPullRequestJob.perform_now(@pull_request)

    @pull_request.reload
    assert_match(/rate limit exceeded/i, @pull_request.fetch_error)
    assert_not_nil @pull_request.fetched_at
  end

  test "network errors leave a fetch_error without raising" do
    WebMock.stub_request(:get, %r{\Ahttps://api\.github\.com/.*\z}).to_raise(SocketError.new("boom"))

    Github::FetchPullRequestJob.perform_now(@pull_request)

    @pull_request.reload
    assert_match(/Could not reach GitHub/, @pull_request.fetch_error)
    assert_not_nil @pull_request.fetched_at
  end

  test "sends the workspace token when configured and omits it otherwise" do
    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)

    assert_requested :get, %r{\Ahttps://api\.github\.com/.*\z},
      headers: { "Authorization" => "Bearer test-token" }, at_least_times: 1

    ENV["GITHUB_TOKEN"] = nil
    WebMock.reset!

    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)

    assert_not_requested :get, %r{\Ahttps://api\.github\.com/.*\z},
      headers: { "Authorization" => /.+/ }
  end

  test "a later success clears an earlier fetch_error" do
    @pull_request.update!(fetched_at: 1.hour.ago, fetch_error: "stale problem")

    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)

    assert_nil @pull_request.reload.fetch_error
  end

  private
    def stub_pull_request(**overrides)
      body = {
        "number" => 123,
        "title" => "Add shiny things",
        "state" => "open",
        "draft" => false,
        "merged_at" => nil,
        "html_url" => "https://github.com/rails/rails/pull/123",
        "updated_at" => "2026-09-15T12:00:00Z",
        "user" => { "login" => "dhh", "avatar_url" => "https://avatars.example/dhh" },
        "base" => { "ref" => "main" },
        "head" => { "ref" => "shiny", "sha" => "abc123" }
      }.merge(overrides.stringify_keys)

      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/pulls/123")
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end

    def stub_reviews(reviews)
      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/pulls/123/reviews?per_page=100")
        .to_return(status: 200, body: reviews.to_json, headers: { "Content-Type" => "application/json" })
    end

    def stub_check_runs(runs)
      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/commits/abc123/check-runs?per_page=100")
        .to_return(status: 200, body: { "check_runs" => runs }.to_json, headers: { "Content-Type" => "application/json" })
    end

    def stub_combined_status(state)
      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/commits/abc123/status")
        .to_return(status: 200, body: { "state" => state }.to_json, headers: { "Content-Type" => "application/json" })
    end
end
