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

  test "fetch stores the repository privacy from base.repo.private" do
    stub_pull_request(base: { "ref" => "main", "repo" => { "private" => true } })
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)

    assert_equal true, @pull_request.reload.private
  end

  test "fetch stores a public repository as not private" do
    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)

    assert_equal false, @pull_request.reload.private
  end

  test "fetch leaves privacy unknown when the payload omits base.repo.private" do
    stub_pull_request(base: { "ref" => "main" })
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)

    assert_nil @pull_request.reload.private
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

  test "no check runs and no statuses leaves check_status blank" do
    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("pending", total_count: 0)

    Github::FetchPullRequestJob.perform_now(@pull_request)
    assert_nil @pull_request.reload.check_status
  end

  test "pending combined status with real statuses maps to pending" do
    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("pending", total_count: 2)

    Github::FetchPullRequestJob.perform_now(@pull_request)
    assert_equal "pending", @pull_request.reload.check_status
  end

  test "a draft with approvals shows its review decision" do
    stub_pull_request(state: "open", draft: true)
    stub_reviews([ { "state" => "APPROVED", "submitted_at" => "2026-09-02T00:00:00Z", "user" => { "id" => 1 } } ])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)

    assert_equal "draft", @pull_request.reload.state
    assert_equal "approved", @pull_request.review_decision
  end

  test "a draft with no reviews shows review required" do
    stub_pull_request(state: "open", draft: true)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)
    assert_equal "review_required", @pull_request.reload.review_decision
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

  test "changed files are fetched only for PRs with a thread mapping" do
    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Github::FetchPullRequestJob.perform_now(@pull_request)

    assert_nil @pull_request.reload.changed_files
    assert_nil @pull_request.changed_files_fetched_at
    assert_not_requested :get, "https://api.github.com/repos/rails/rails/pulls/123/files?per_page=100"
  end

  test "mapped PRs store the files summary without diff bodies" do
    discuss(@pull_request)

    stub_pull_request(state: "open", draft: false, changed_files: 2)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")
    stub_changed_files([
      { "filename" => "app/models/user.rb", "additions" => 10, "deletions" => 2,
        "status" => "modified", "patch" => "@@ -1 +1 @@\n-old\n+new" },
      { "filename" => "app/models/new.rb", "additions" => 5, "deletions" => 0,
        "status" => "added", "patch" => "@@ -0,0 +1 @@\n+new" }
    ])

    Github::FetchPullRequestJob.perform_now(@pull_request)

    @pull_request.reload
    assert_requested :get, "https://api.github.com/repos/rails/rails/pulls/123/files?per_page=100", times: 1
    assert_equal(
      { "files" => [
        { "filename" => "app/models/user.rb", "additions" => 10, "deletions" => 2, "status" => "modified" },
        { "filename" => "app/models/new.rb", "additions" => 5, "deletions" => 0, "status" => "added" }
      ], "total_count" => 2 },
      @pull_request.changed_files_summary
    )
    assert_not_includes @pull_request.changed_files, "patch"
    assert_not_includes @pull_request.changed_files, "@@"
    assert_not_nil @pull_request.changed_files_fetched_at
    assert_nil @pull_request.fetch_error
  end

  test "the files summary caps at 100 files with the PR total" do
    discuss(@pull_request)

    stub_pull_request(state: "open", draft: false, changed_files: 150)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")
    stub_changed_files(
      101.times.map { |i|
        { "filename" => "file#{i}.rb", "additions" => 1, "deletions" => 0, "status" => "modified" }
      }
    )

    Github::FetchPullRequestJob.perform_now(@pull_request)

    summary = @pull_request.reload.changed_files_summary
    assert_equal 100, summary["files"].size
    assert_equal 150, summary["total_count"]
  end

  test "a failed files fetch keeps the previous summary and sets fetch_error" do
    discuss(@pull_request)
    previous = { "files" => [
      { "filename" => "old.rb", "additions" => 1, "deletions" => 0, "status" => "modified" }
    ], "total_count" => 1 }.to_json
    @pull_request.update!(changed_files: previous, changed_files_fetched_at: 1.day.ago)

    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")
    WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/pulls/123/files?per_page=100")
      .to_return(status: 500, body: { message: "boom" }.to_json)

    Github::FetchPullRequestJob.perform_now(@pull_request)

    @pull_request.reload
    assert_equal previous, @pull_request.changed_files
    assert_in_delta 1.day.ago, @pull_request.changed_files_fetched_at, 1.second
    assert_equal "GitHub returned 500", @pull_request.fetch_error
    assert_equal "Add shiny things", @pull_request.title
  end

  test "card updates broadcast the thread header to mapped thread streams" do
    thread = discuss(@pull_request)

    stub_pull_request(state: "open", draft: false, changed_files: 1)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")
    stub_changed_files([
      { "filename" => "app/models/user.rb", "additions" => 3, "deletions" => 1, "status" => "modified" }
    ])

    Github::FetchPullRequestJob.perform_now(@pull_request)

    fragment = Nokogiri::HTML.fragment(thread_stream_broadcasts(thread).join("\n"))
    header_stream = fragment.at_css(
      %(turbo-stream[action="replace"][target="#{ActionView::RecordIdentifier.dom_id(thread, :github_pr_header)}"])
    )
    assert header_stream, "expected a thread header replace stream, got: #{fragment.to_html}"
    assert_equal 1, header_stream.css(".github-pr-card").size
    assert_includes header_stream.at_css(".github-pr-card__title").text, "Add shiny things"
    assert_includes header_stream.at_css(".github-pr-files__path").text, "app/models/user.rb"
  end

  test "card updates broadcast nothing without referencing messages or mappings" do
    stub_pull_request(state: "open", draft: false)
    stub_reviews([])
    stub_check_runs([])
    stub_combined_status("success")

    Turbo::StreamsChannel.expects(:broadcast_replace_to).never

    Github::FetchPullRequestJob.perform_now(@pull_request)
  end

  private
    def discuss(pull_request)
      room = rooms(:designers)
      parent = room.messages.create!(
        creator: users(:david),
        markdown_source: "review https://github.com/#{pull_request.owner}/#{pull_request.repo}/pull/#{pull_request.number}",
        client_message_id: "fetch-files-#{pull_request.number}"
      )
      thread = ChannelThread.create!(room: room, creator: users(:david), name: "PR chat", parent_message: parent)
      ThreadMembership.join!(thread, users(:david))
      Github::PullRequestThread.create!(pull_request: pull_request, room: room, channel_thread: thread)
      thread
    end

    def stub_changed_files(files)
      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/pulls/123/files?per_page=100")
        .to_return(status: 200, body: files.to_json, headers: { "Content-Type" => "application/json" })
    end

    def thread_stream_broadcasts(thread)
      ActionCable.server.pubsub.broadcasts([ thread.to_gid_param, :messages ].join(":"))
        .map { |broadcast| JSON.parse(broadcast) }
    end
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
        "base" => { "ref" => "main", "repo" => { "private" => false } },
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

    def stub_combined_status(state, total_count: 1)
      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/commits/abc123/status")
        .to_return(status: 200, body: { "state" => state, "total_count" => total_count }.to_json, headers: { "Content-Type" => "application/json" })
    end
end
