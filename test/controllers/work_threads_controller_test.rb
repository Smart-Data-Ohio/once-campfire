require "test_helper"

class WorkThreadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    @room = rooms(:designers)
    @creator = users(:jz)

    @open_thread = ChannelThread.create!(room: @room, creator: @creator, name: "Open work")
    ThreadMembership.join!(@open_thread, @creator)
    @open_thread.update!(work_status: "in_progress", work_owner_id: users(:kevin).id)

    @done_thread = ChannelThread.create!(room: @room, creator: @creator, name: "Done work")
    ThreadMembership.join!(@done_thread, @creator)
    @done_thread.update!(work_status: "done", work_owner_id: @creator.id)

    @hidden_thread = ChannelThread.create!(room: rooms(:watercooler), creator: users(:david), name: "Hidden work")
    ThreadMembership.join!(@hidden_thread, users(:david))
    @hidden_thread.update!(work_status: "in_progress", work_owner_id: users(:david).id)

    @open_thread.update_columns(updated_at: 2.hours.ago)
    @done_thread.update_columns(updated_at: 1.hour.ago)
  end

  test "global work list filters by state and current room access" do
    sign_in :jz

    get work_threads_url(state: "open", format: :json)
    assert_response :success
    assert_equal [ @open_thread.id ], response.parsed_body.fetch("threads").pluck("id")

    get work_threads_url(state: "done", format: :json)
    assert_response :success
    assert_equal [ @done_thread.id ], response.parsed_body.fetch("threads").pluck("id")

    get work_threads_url(state: "all", format: :json)
    assert_response :success
    assert_equal [ @done_thread.id, @open_thread.id ], response.parsed_body.fetch("threads").pluck("id")
    assert_not_includes response.body, @hidden_thread.name
  end

  test "global work access requires an active human room member" do
    inactive = @creator.dup
    inactive.status = :deactivated

    assert_empty ChannelThread.for_room_member(inactive)
    assert_empty ChannelThread.for_room_member(users(:bender))
    assert_not @open_thread.work_viewable_by?(inactive)
    assert_not @open_thread.work_viewable_by?(users(:bender))
  end
end
