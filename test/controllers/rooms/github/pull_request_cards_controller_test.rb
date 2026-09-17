require "test_helper"

class Rooms::Github::PullRequestCardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
    @message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/acme/secret/pull/7",
      client_message_id: "card-frame-1"
    )
    @pull_request = @message.github_pull_requests.first
    @pull_request.update!(
      private: true, title: "Secret plans", author_login: "alice",
      state: "open", base_branch: "main", head_branch: "secret",
      review_decision: "approved", check_status: "passing",
      html_url: "https://github.com/acme/secret/pull/7",
      github_updated_at: 1.hour.ago, fetched_at: Time.current, fetch_error: nil
    )
    @pull_request.update_column(:fetch_requested_at, nil)
  end

  test "a member whose token can read the repository sees the card" do
    GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "user-token")
    stub = stub_request(:get, "https://api.github.com/repos/acme/secret")
      .with(headers: { "Authorization" => "Bearer user-token" })
      .to_return(status: 200, body: { private: true }.to_json)

    get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)

    assert_response :success
    assert_select "turbo-frame##{card_frame_id}", count: 1
    assert_select ".github-pr-card__title", text: "Secret plans"
    assert_requested stub
  end

  test "a member without a linked account gets the empty frame and no GitHub request" do
    get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)

    assert_response :success
    assert_select "turbo-frame.github-pr-card-frame", count: 1
    assert_select ".github-pr-card", count: 0
    assert_not_includes response.body, "Secret plans"
    assert_not_requested :get, "https://api.github.com/repos/acme/secret"
  end

  test "a member with a disconnected account gets the empty frame and no GitHub request" do
    account = GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "user-token")
    account.mark_disconnected!("GitHub rejected the linked token (401)")

    get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)

    assert_response :success
    assert_select ".github-pr-card", count: 0
    assert_not_includes response.body, "Secret plans"
    assert_not_requested :get, "https://api.github.com/repos/acme/secret"
  end

  test "GitHub 404 gives the empty frame" do
    GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "user-token")
    stub_request(:get, "https://api.github.com/repos/acme/secret")
      .to_return(status: 404, body: { message: "Not Found" }.to_json)

    get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)

    assert_response :success
    assert_select "turbo-frame.github-pr-card-frame", count: 1
    assert_select ".github-pr-card", count: 0
    assert_not_includes response.body, "Secret plans"
  end

  test "GitHub 401 marks the account disconnected and gives the empty frame" do
    account = GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "user-token")
    stub_request(:get, "https://api.github.com/repos/acme/secret")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json)

    get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)

    assert_response :success
    assert_select ".github-pr-card", count: 0
    assert_not_includes response.body, "Secret plans"
    assert_not account.reload.connected?
  end

  test "the decision is cached per viewer and repository" do
    GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "user-token")
    stub = stub_request(:get, "https://api.github.com/repos/acme/secret")
      .to_return(status: 200, body: { private: true }.to_json)

    with_memory_cache do
      get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)
      assert_response :success
      assert_select ".github-pr-card__title", text: "Secret plans"

      get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)
      assert_response :success
      assert_select ".github-pr-card__title", text: "Secret plans"

      assert_requested stub, times: 1
    end
  end


  test "a cached denial no longer applies after the member relinks" do
    stub_request(:get, "https://api.github.com/user")
      .to_return(status: 200, body: { login: "david" }.to_json)
    post github_connection_url, params: { access_token: "alpha-link" }
    assert_redirected_to user_profile_path

    denied = stub_request(:get, "https://api.github.com/repos/acme/secret")
      .to_return(status: 404, body: { message: "Not Found" }.to_json)

    with_memory_cache do
      get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)
      assert_response :success
      assert_select ".github-pr-card", count: 0

      travel 1.second do
        post github_connection_url, params: { access_token: "beta-relink" }
        assert_redirected_to user_profile_path
      end

      granted = stub_request(:get, "https://api.github.com/repos/acme/secret")
        .to_return(status: 200, body: { private: true }.to_json)

      get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)
      assert_response :success
      assert_select ".github-pr-card__title", text: "Secret plans"

    end
  end

  test "a transport error renders the empty frame and caches nothing" do
    GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "user-token")
    stub_request(:get, "https://api.github.com/repos/acme/secret").to_timeout

    with_memory_cache do
      get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)

      assert_response :success
      assert_select ".github-pr-card", count: 0
      assert_not_includes response.body, "Secret plans"

      # Nothing cached: once GitHub recovers, the card loads without waiting
      # for the cache window.
      stub_request(:get, "https://api.github.com/repos/acme/secret")
        .to_return(status: 200, body: { private: true }.to_json)

      get room_github_pull_request_card_url(@room, @pull_request, message_id: @message)

      assert_response :success
      assert_select ".github-pr-card__title", text: "Secret plans"
    end
  end

  test "a public PR renders the card with no GitHub request" do
    @pull_request.update!(private: false)

    get room_github_pull_request_card_url(@room, @pull_request, message_id: @message.id)

    assert_response :success
    assert_select ".github-pr-card__title", text: "Secret plans"
    assert_not_requested :get, "https://api.github.com/repos/acme/secret"
  end

  test "a thread frame renders the card and files summary when the viewer may see it" do
    GithubConnectedAccount.create!(user: users(:david), github_login: "david", access_token: "user-token")
    stub_request(:get, "https://api.github.com/repos/acme/secret")
      .to_return(status: 200, body: { private: true }.to_json)
    @pull_request.update!(
      changed_files: {
        "files" => [ { "filename" => "app/models/secret.rb", "additions" => 3, "deletions" => 1, "status" => "modified" } ],
        "total_count" => 1
      }.to_json, changed_files_fetched_at: Time.current
    )
    thread = discuss(@pull_request, parent: @message)

    get room_github_pull_request_card_url(@room, @pull_request, thread_id: thread.id)

    assert_response :success
    assert_select ".github-pr-card__title", text: "Secret plans"
    assert_select ".github-pr-files__path", text: "app/models/secret.rb"
  end

  test "a thread frame is empty when the viewer may not see it" do
    thread = discuss(@pull_request, parent: @message)

    get room_github_pull_request_card_url(@room, @pull_request, thread_id: thread.id)

    assert_response :success
    assert_select ".github-pr-card", count: 0
    assert_select ".github-pr-files", count: 0
    assert_not_includes response.body, "Secret plans"
  end

  test "non-members get not found" do
    sign_in :kevin # not a member of the watercooler

    # RoomScoped raises RecordNotFound, which renders 404 outside tests.
    assert_raises(ActiveRecord::RecordNotFound) do
      get room_github_pull_request_card_url(rooms(:watercooler), @pull_request, message_id: @message.id)
    end
  end

  test "a message from another room is not found" do
    other_room = rooms(:watercooler)
    other_message = other_room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/acme/secret/pull/7",
      client_message_id: "card-frame-other-room"
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      get room_github_pull_request_card_url(@room, @pull_request, message_id: other_message.id)
    end
  end

  test "a message that does not reference the PR is not found" do
    other_message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "just chatting",
      client_message_id: "card-frame-unrelated"
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      get room_github_pull_request_card_url(@room, @pull_request, message_id: other_message.id)
    end
  end

  test "missing context is not found" do
    assert_raises(ActiveRecord::RecordNotFound) do
      get room_github_pull_request_card_url(@room, @pull_request)
    end
  end

  private
    def card_frame_id
      ActionView::RecordIdentifier.dom_id(@pull_request, "card_for_message_#{@message.id}")
    end

    def discuss(pull_request, parent:)
      thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: parent)
      ThreadMembership.join!(thread, users(:david))
      Github::PullRequestThread.create!(pull_request: pull_request, room: @room, channel_thread: thread)
      thread
    end

    # The test environment uses :null_store; swap in a memory store so cache
    # behavior is exercisable.
    def with_memory_cache
      store = ActiveSupport::Cache::MemoryStore.new
      previous = Rails.cache
      Rails.cache = store
      yield store
    ensure
      Rails.cache = previous
    end
end
