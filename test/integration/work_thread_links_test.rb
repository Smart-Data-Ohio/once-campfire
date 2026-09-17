require "test_helper"

class WorkThreadLinksTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:watercooler)
    @thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Linked work")
    ThreadMembership.join!(@thread, users(:david))
    @thread.update_work!(actor: users(:david), work_status: "planned", work_owner_id: users(:david).id)

    @pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    @pull_request.update!(title: "Fix login", state: "open", html_url: "https://github.com/rails/rails/pull/12", private: false)
    @thread.work_thread_links.create!(kind: :pull_request, github_pull_request: @pull_request, created_by: users(:david))
    @thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))
    @drive_url = "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view"
    @thread.work_thread_links.create!(kind: :drive_file, url: @drive_url, title: "Q3 Planning", created_by: users(:david))
  end

  test "a private pull request link shows its reference and state but never its title" do
    @pull_request.update!(private: true)

    get room_thread_url(@room, @thread)

    assert_response :success
    assert_select "a.work-links__pr", text: "rails/rails#12"
    assert_select ".work-links__pr-state", text: "Open"
    assert_select ".work-links__pr-title", count: 0
    assert_no_match "Fix login", response.body

    @pull_request.update!(private: nil)
    get room_thread_url(@room, @thread)
    assert_no_match "Fix login", response.body
  end

  test "the thread header renders each link kind with remove controls and link forms" do
    Event.create!(room: @room, organizer: users(:david), title: "Next sync",
      starts_at: 4.days.from_now, time_zone: "UTC")

    get room_thread_url(@room, @thread)

    assert_response :success
    assert_select "#work-thread-links-header-#{@thread.id} .work-links__label", text: "Linked"
    assert_select "a.work-links__pr[href='https://github.com/rails/rails/pull/12']", text: "rails/rails#12"
    assert_select ".work-links__pr-state", text: "Open"
    assert_select ".work-links__pr-title", text: "Fix login"
    assert_select "a.work-links__event[href='#{room_event_path(@room, events(:watercooler_sync))}']",
      text: "Watercooler sync"
    assert_select ".work-links__event-time time"
    assert_select "a.work-links__drive[href='#{@drive_url}']", text: "Q3 Planning"
    assert_select ".work-links__remove-form", count: 3
    assert_select "form[action='#{thread_work_links_path(@thread)}']", count: 3
    assert_select "form[action='#{thread_work_links_path(@thread)}'] input[name='kind'][value='pull_request']"
    assert_select "form[action='#{thread_work_links_path(@thread)}'] select[name='event_id']"
    assert_select "form[action='#{thread_work_links_path(@thread)}'] input[name='kind'][value='drive_file']"
  end

  test "the work list row renders each link kind with remove controls" do
    get work_threads_url

    assert_response :success
    assert_select "#work-thread-links-row-#{@thread.id} .work-links__label", text: "Linked"
    assert_select "a.work-links__pr", text: "rails/rails#12"
    assert_select "a.work-links__event", text: "Watercooler sync"
    assert_select "a.work-links__drive", text: "Q3 Planning"
    assert_select "#work-thread-links-row-#{@thread.id} .work-links__remove-form", count: 3
    assert_select ".work-threads__item-link[href='#{room_path(@room, thread: @thread.id)}']", count: 1
  end

  test "a drive link without a cached title shows the plain url" do
    @thread.work_thread_links.where(kind: :drive_file).update_all(title: nil)

    get work_threads_url

    assert_response :success
    assert_select "a.work-links__drive[href='#{@drive_url}']", text: @drive_url
  end

  test "drive links fall back to the plain link without credentials" do
    get room_thread_url(@room, @thread)

    assert_response :success
    assert_select 'meta[name="google-drive-previews"]', count: 0
    assert_select ".work-links__items[data-controller='drive-link'] a.work-links__drive[href='#{@drive_url}']"
    assert_select ".drive-chip", count: 0
  end

  test "the event picker lists upcoming room events soonest first without linked ones" do
    later = Event.create!(room: @room, organizer: users(:david), title: "Later sync",
      starts_at: 5.days.from_now, time_zone: "UTC")

    get room_thread_url(@room, @thread)

    assert_response :success
    options = css_select("select[name='event_id'] option").map { |option| [ option.text, option["value"] ] }
    assert_equal [ [ "Later sync — #{later.starts_at.strftime("%b %-d, %Y, %-I:%M %p")}", later.id.to_s ] ], options
  end

  test "linking creates no inbox items" do
    fresh = Event.create!(room: @room, organizer: users(:david), title: "Fresh sync",
      starts_at: 4.days.from_now, time_zone: "UTC")

    assert_no_difference "ActivityItem.count" do
      post thread_work_links_path(@thread, format: :turbo_stream),
        params: { kind: "event", event_id: fresh.id }
      assert_response :success

      delete thread_work_link_path(@thread, @thread.work_thread_links.find_by!(event: fresh),
        format: :turbo_stream)
      assert_response :success
    end
  end
end
