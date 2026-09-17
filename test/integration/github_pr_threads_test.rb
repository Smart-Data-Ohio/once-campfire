require "test_helper"

class GithubPrThreadsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
  end

  test "a card without a thread shows a Discuss button" do
    message = pr_message(number: 140, client_id: "threads-view-button")
    fill_card(message.github_pull_requests.first)

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card__discuss-form[action=?]", room_github_pull_request_threads_path(@room), count: 1 do
      assert_select "button.github-pr-card__discuss", text: "Discuss", count: 1
    end
    assert_select ".github-pr-card a.github-pr-card__discuss", count: 0
  end

  test "a card with a thread links to it" do
    message = pr_message(number: 141, client_id: "threads-view-link")
    pull_request = message.github_pull_requests.first
    fill_card(pull_request)
    thread = discuss(pull_request, parent: message)

    get room_url(@room)

    assert_response :success
    assert_select ".github-pr-card a.github-pr-card__discuss[href=?]", room_thread_path(@room, thread), text: "Discuss", count: 1
    assert_select ".github-pr-card__discuss-form", count: 0
  end

  test "a PR thread shows the card and files summary above its messages" do
    message = pr_message(number: 142, client_id: "threads-view-header")
    pull_request = message.github_pull_requests.first
    fill_card(pull_request)
    fill_files(pull_request,
      files: [
        { "filename" => "app/models/user.rb", "additions" => 10, "deletions" => 2, "status" => "modified" },
        { "filename" => "app/models/new.rb", "additions" => 5, "deletions" => 0, "status" => "added" }
      ],
      total_count: 5)
    thread = discuss(pull_request, parent: message)
    thread.post_message!(creator: users(:david), attributes: { markdown_source: "first reply" })

    get room_thread_url(@room, thread)

    assert_response :success
    assert_select ".github-pr-thread-header .github-pr-card", count: 1
    assert_select ".github-pr-thread-header .github-pr-card__title", text: "Add shiny things"
    assert_select ".github-pr-files__heading", text: "Files changed"
    assert_select ".github-pr-files__file", count: 2
    assert_select ".github-pr-files__path", text: "app/models/user.rb"
    assert_select ".github-pr-files__status", text: "Modified"
    assert_select ".github-pr-files__status", text: "Added"
    assert_select ".github-pr-files__counts", text: "+10 \u22122"
    assert_select ".github-pr-files__more", text: "and 3 more on GitHub"
  end

  test "the files summary omits the more line when everything is shown" do
    message = pr_message(number: 143, client_id: "threads-view-exact")
    pull_request = message.github_pull_requests.first
    fill_card(pull_request)
    fill_files(pull_request,
      files: [ { "filename" => "only.rb", "additions" => 1, "deletions" => 0, "status" => "modified" } ],
      total_count: 1)
    thread = discuss(pull_request, parent: message)

    get room_thread_url(@room, thread)

    assert_response :success
    assert_select ".github-pr-files__file", count: 1
    assert_select ".github-pr-files__more", count: 0
  end

  test "a PR thread without fetched files shows a loading summary" do
    message = pr_message(number: 144, client_id: "threads-view-loading")
    pull_request = message.github_pull_requests.first
    fill_card(pull_request)
    thread = discuss(pull_request, parent: message)

    get room_thread_url(@room, thread)

    assert_response :success
    assert_select ".github-pr-thread-header .github-pr-card", count: 1
    assert_select ".github-pr-files__loading", text: /Loading files/
    assert_select ".github-pr-files__file", count: 0
  end

  test "an ordinary thread shows no PR header" do
    parent = @room.messages.create!(
      creator: users(:david), markdown_source: "just chatting",
      client_message_id: "threads-view-ordinary"
    )
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Ordinary chat", parent_message: parent)

    get room_thread_url(@room, thread)

    assert_response :success
    assert_select ".github-pr-thread-header", count: 0
  end

  test "file paths from the API render as text" do
    malicious_name = %(<img src=x onerror="window.__prFilesXss = true">)
    message = pr_message(number: 145, client_id: "threads-view-xss")
    pull_request = message.github_pull_requests.first
    fill_card(pull_request)
    fill_files(pull_request,
      files: [ { "filename" => malicious_name, "additions" => 1, "deletions" => 0, "status" => "modified" } ],
      total_count: 1)
    thread = discuss(pull_request, parent: message)

    get room_thread_url(@room, thread)

    assert_response :success
    assert_select ".github-pr-files__path", text: malicious_name
    assert_select ".github-pr-files__path img", count: 0
  end

  test "a non-member cannot open the PR thread" do
    room = rooms(:watercooler) # kevin is not a member
    message = room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/146",
      client_message_id: "threads-view-private"
    )
    pull_request = message.github_pull_requests.first
    fill_card(pull_request)
    thread = ChannelThread.create!(room: room, creator: users(:david), name: "PR chat", parent_message: message)
    Github::PullRequestThread.create!(pull_request: pull_request, room: room, channel_thread: thread)

    delete session_url
    sign_in :kevin

    # RoomScoped raises RecordNotFound, which renders 404 outside tests.
    assert_raises(ActiveRecord::RecordNotFound) do
      get room_thread_url(room, thread)
    end
  end

  private
    def pr_message(number:, client_id:)
      @room.messages.create!(
        creator: users(:david),
        markdown_source: "review https://github.com/rails/rails/pull/#{number}",
        client_message_id: client_id
      )
    end

    def discuss(pull_request, parent:)
      thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: parent)
      ThreadMembership.join!(thread, users(:david))
      Github::PullRequestThread.create!(pull_request: pull_request, room: @room, channel_thread: thread)
      thread
    end

    def fill_card(pull_request)
      pull_request.update!(
        title: "Add shiny things", author_login: "dhh",
        author_avatar_url: "https://avatars.example/dhh",
        state: "open", base_branch: "main", head_branch: "shiny", head_sha: "abc123",
        review_decision: "approved", check_status: "passing",
        html_url: "https://github.com/#{pull_request.owner}/#{pull_request.repo}/pull/#{pull_request.number}",
        github_updated_at: 1.hour.ago, payload: {}, fetched_at: Time.current, fetch_error: nil
      )
      pull_request.update_column(:fetch_requested_at, nil)
    end

    def fill_files(pull_request, files:, total_count:)
      pull_request.update!(
        changed_files: { "files" => files, "total_count" => total_count }.to_json,
        changed_files_fetched_at: Time.current
      )
    end
end
