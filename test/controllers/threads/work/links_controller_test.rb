require "test_helper"

class Threads::Work::LinksControllerTest < ActionDispatch::IntegrationTest
  include GoogleCalendarTestHelper

  setup do
    @room = rooms(:watercooler)
    @thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Linked work")
    ThreadMembership.join!(@thread, users(:david))
    @thread.update_work!(actor: users(:david), work_status: "planned", work_owner_id: users(:david).id)
    sign_in :david
  end

  test "index renders the panel link box for a room member" do
    get thread_work_links_path(@thread)

    assert_response :success
    assert_match "thread-panel-work-links", response.body
    assert_match "Pull request URL", response.body
    assert_match "Drive file URL", response.body
  end

  test "a non-manager member can open the link box" do
    @room.memberships.grant_to(users(:kevin))
    sign_in :kevin

    get thread_work_links_path(@thread)

    assert_response :success
  end

  test "index is 404 for non-members and unknown threads" do
    sign_in :jz

    get thread_work_links_path(@thread)
    assert_response :not_found

    sign_in :david
    get thread_work_links_path(123_456)
    assert_response :not_found
  end

  test "index is 422 for a thread without work tracking" do
    plain = ChannelThread.create!(room: @room, creator: users(:david), name: "Plain thread")
    ThreadMembership.join!(plain, users(:david))

    get thread_work_links_path(plain)

    assert_response :unprocessable_entity
  end

  test "linking a pull request resolves through for_reference and enqueues a card fetch" do
    assert_enqueued_with(job: Github::FetchPullRequestJob) do
      post thread_work_links_path(@thread, format: :turbo_stream),
        params: { kind: "pull_request", pull_request_url: "https://github.com/rails/rails/pull/12/files?diff=split" }
    end

    assert_response :success
    pull_request = Github::PullRequest.find_by!(owner: "rails", repo: "rails", number: 12)
    link = @thread.work_thread_links.find_by!(github_pull_request: pull_request)
    assert link.pull_request?
    assert_equal users(:david).id, link.created_by_id
    assert_stream_replaces_all_boxes
  end

  test "linking a pull request is 422 without a PR url" do
    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "pull_request", pull_request_url: "not a url" }

    assert_response :unprocessable_entity
    assert_match "Enter a GitHub pull request URL", response.body
    assert_empty @thread.work_thread_links.reload
  end

  test "linking an event in the same room" do
    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "event", event_id: events(:watercooler_sync).id }

    assert_response :success
    link = @thread.work_thread_links.find_by!(event: events(:watercooler_sync))
    assert link.event?
    assert_stream_replaces_all_boxes
  end

  test "linking a cancelled event in the same room still works" do
    cancelled = Event.create!(room: @room, organizer: users(:david), title: "Old sync",
      starts_at: 2.days.ago, time_zone: "UTC")
    cancelled.update_column(:cancelled_at, 1.day.ago)

    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "event", event_id: cancelled.id }

    assert_response :success
    assert @thread.work_thread_links.exists?(event: cancelled)
  end

  test "linking an event from another room is 404" do
    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "event", event_id: events(:launch_party).id }

    assert_response :not_found
    assert_empty @thread.work_thread_links.reload
  end

  test "linking an event without a choice is 422" do
    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "event", event_id: "" }

    assert_response :unprocessable_entity
    assert_match "Choose an event to link", response.body
  end

  test "linking a drive file without credentials stores the url alone" do
    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "drive_file", drive_url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view" }

    assert_response :success
    link = @thread.work_thread_links.find_by!(kind: :drive_file)
    assert_equal "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view", link.url
    assert_nil link.title
    assert_stream_replaces_all_boxes
  end

  test "linking a drive file caches the name when credentials resolve it" do
    connect_google!(users(:david), scopes: DRIVE_SCOPES)
    stub_google_drive_file("1AbcDefGhIjKlMnOpQrSt")

    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "drive_file", drive_url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view" }

    assert_response :success
    link = @thread.work_thread_links.find_by!(kind: :drive_file)
    assert_equal "Q3 Planning", link.title
  end

  test "linking a drive file stores the url alone when resolution fails" do
    connect_google!(users(:david), scopes: DRIVE_SCOPES)
    stub_google_drive_file("1AbcDefGhIjKlMnOpQrSt", status: 404, body: {})

    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "drive_file", drive_url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view" }

    assert_response :success
    link = @thread.work_thread_links.find_by!(kind: :drive_file)
    assert_nil link.title
  end

  test "linking a drive file is 422 for an unrecognised url" do
    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "drive_file", drive_url: "https://example.com/file" }

    assert_response :unprocessable_entity
    assert_match "Enter a Google Drive", response.body
    assert_empty @thread.work_thread_links.reload
  end

  test "linking with an unknown kind is 422" do
    post thread_work_links_path(@thread, format: :turbo_stream), params: { kind: "bogus" }

    assert_response :unprocessable_entity
    assert_match "Choose a pull request, event, or Drive file", response.body
  end

  test "linking a duplicate is 422" do
    @thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))

    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "event", event_id: events(:watercooler_sync).id }

    assert_response :unprocessable_entity
    assert_match "already linked", response.body
  end

  test "a non-manager member can add and remove links" do
    @room.memberships.grant_to(users(:kevin))
    sign_in :kevin

    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "event", event_id: events(:watercooler_sync).id }
    assert_response :success
    link = @thread.work_thread_links.find_by!(event: events(:watercooler_sync))

    delete thread_work_link_path(@thread, link, format: :turbo_stream)
    assert_response :success
    assert_empty @thread.work_thread_links.reload
  end

  test "removing a link of each kind refreshes every box" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    pr_link = @thread.work_thread_links.create!(kind: :pull_request, github_pull_request: pull_request, created_by: users(:david))
    event_link = @thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))
    drive_link = @thread.work_thread_links.create!(kind: :drive_file,
      url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view", created_by: users(:david))

    [ pr_link, event_link, drive_link ].each do |link|
      delete thread_work_link_path(@thread, link, format: :turbo_stream)

      assert_response :success
      assert_stream_replaces_all_boxes
      assert_not WorkThreadLink.exists?(link.id)
    end

    assert pull_request.reload
    assert events(:watercooler_sync).reload
  end

  test "removing an unknown link is 404" do
    delete thread_work_link_path(@thread, 123_456, format: :turbo_stream)

    assert_response :not_found
  end

  test "adding and removing is 404 for non-members" do
    sign_in :jz

    post thread_work_links_path(@thread, format: :turbo_stream),
      params: { kind: "event", event_id: events(:watercooler_sync).id }
    assert_response :not_found

    link = @thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))
    delete thread_work_link_path(@thread, link, format: :turbo_stream)
    assert_response :not_found
    assert WorkThreadLink.exists?(link.id)
  end

  test "adding and removing is 422 without work tracking" do
    plain = ChannelThread.create!(room: @room, creator: users(:david), name: "Plain thread")
    ThreadMembership.join!(plain, users(:david))

    post thread_work_links_path(plain, format: :turbo_stream),
      params: { kind: "event", event_id: events(:watercooler_sync).id }
    assert_response :unprocessable_entity

    delete thread_work_link_path(plain, 123_456, format: :turbo_stream)
    assert_response :unprocessable_entity
  end

  test "html requests redirect back to the thread" do
    post thread_work_links_path(@thread),
      params: { kind: "event", event_id: events(:watercooler_sync).id }

    assert_redirected_to room_thread_path(@room, @thread)
    link = @thread.work_thread_links.find_by!(event: events(:watercooler_sync))

    delete thread_work_link_path(@thread, link)

    assert_redirected_to room_thread_path(@room, @thread)
    assert_empty @thread.work_thread_links.reload
  end

  private
    def assert_stream_replaces_all_boxes
      %w[ panel header row ].each do |context|
        assert_match(
          %(<turbo-stream action="replace" target="work-thread-links-#{context}-#{@thread.id}">),
          response.body,
          "expected the #{context} box to refresh"
        )
      end
    end
end
