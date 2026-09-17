require "test_helper"

class WorkThreadLinkTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:watercooler)
    @thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Linked work")
    ThreadMembership.join!(@thread, users(:david))
    @thread.update_work!(actor: users(:david), work_status: "planned", work_owner_id: users(:david).id)
  end

  test "pull request links require only the pull request" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)

    link = @thread.work_thread_links.create!(kind: :pull_request, github_pull_request: pull_request, created_by: users(:david))

    assert link.pull_request?
    assert_equal pull_request.id, link.github_pull_request_id
    assert_nil link.event_id
    assert_nil link.url
  end

  test "pull request links reject other columns" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)

    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :pull_request, created_by: users(:david)),
      :github_pull_request
    )
    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :pull_request, github_pull_request: pull_request,
        event: events(:watercooler_sync), created_by: users(:david)),
      :event
    )
    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :pull_request, github_pull_request: pull_request,
        url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view", created_by: users(:david)),
      :url
    )
    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :pull_request, github_pull_request: pull_request,
        title: "Cached name", created_by: users(:david)),
      :title
    )
  end

  test "event links require only the event" do
    link = @thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))

    assert link.event?
    assert_nil link.github_pull_request_id
    assert_nil link.url
    assert_nil link.title
  end

  test "event links reject other columns" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)

    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :event, created_by: users(:david)),
      :event
    )
    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :event, event: events(:watercooler_sync),
        github_pull_request: pull_request, created_by: users(:david)),
      :github_pull_request
    )
    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :event, event: events(:watercooler_sync),
        url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view", created_by: users(:david)),
      :url
    )
  end

  test "event links must belong to the thread's room" do
    link = WorkThreadLink.new(channel_thread: @thread, kind: :event, event: events(:launch_party), created_by: users(:david))

    assert_not link.valid?
    assert_equal [ "must belong to the thread's room" ], link.errors[:event]
  end

  test "drive file links require the url and keep an optional cached title" do
    link = @thread.work_thread_links.create!(
      kind: :drive_file, url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view",
      title: "Q3 Planning", created_by: users(:david)
    )

    assert link.drive_file?
    assert_equal "Q3 Planning", link.title
    assert_nil link.github_pull_request_id
    assert_nil link.event_id
  end

  test "drive file links reject other columns" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)

    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :drive_file, created_by: users(:david)),
      :url
    )
    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :drive_file,
        url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view",
        github_pull_request: pull_request, created_by: users(:david)),
      :github_pull_request
    )
    assert_invalid_columns(
      WorkThreadLink.new(channel_thread: @thread, kind: :drive_file,
        url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view",
        event: events(:watercooler_sync), created_by: users(:david)),
      :event
    )
  end

  test "long drive titles truncate to the column limit" do
    link = @thread.work_thread_links.create!(
      kind: :drive_file, url: "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view",
      title: "x" * 300, created_by: users(:david)
    )

    assert_equal 255, link.title.length
  end

  test "links are unique per thread" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    @thread.work_thread_links.create!(kind: :pull_request, github_pull_request: pull_request, created_by: users(:david))
    @thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))
    drive_url = "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view"
    @thread.work_thread_links.create!(kind: :drive_file, url: drive_url, created_by: users(:david))

    assert_not WorkThreadLink.new(channel_thread: @thread, kind: :pull_request,
      github_pull_request: pull_request, created_by: users(:david)).valid?
    assert_not WorkThreadLink.new(channel_thread: @thread, kind: :event,
      event: events(:watercooler_sync), created_by: users(:david)).valid?
    assert_not WorkThreadLink.new(channel_thread: @thread, kind: :drive_file,
      url: drive_url, created_by: users(:david)).valid?
  end

  test "the same objects link to other threads" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    other = ChannelThread.create!(room: @room, creator: users(:david), name: "Other linked work")
    ThreadMembership.join!(other, users(:david))
    other.update_work!(actor: users(:david), work_status: "planned")
    drive_url = "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view"

    @thread.work_thread_links.create!(kind: :pull_request, github_pull_request: pull_request, created_by: users(:david))
    @thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))
    @thread.work_thread_links.create!(kind: :drive_file, url: drive_url, created_by: users(:david))

    assert WorkThreadLink.new(channel_thread: other, kind: :pull_request,
      github_pull_request: pull_request, created_by: users(:david)).valid?
    assert WorkThreadLink.new(channel_thread: other, kind: :event,
      event: events(:watercooler_sync), created_by: users(:david)).valid?
    assert WorkThreadLink.new(channel_thread: other, kind: :drive_file,
      url: drive_url, created_by: users(:david)).valid?
  end

  test "destroying the thread destroys its links" do
    @thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))

    assert_difference "WorkThreadLink.count", -1 do
      @thread.destroy!
    end
  end

  private
    def assert_invalid_columns(link, attribute)
      assert_not link.valid?, "expected #{link.inspect} to be invalid"
      assert link.errors[attribute].any?, "expected an error on #{attribute}: #{link.errors.full_messages.inspect}"
    end
end
