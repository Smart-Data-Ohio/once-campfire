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

  test "work page explains what work threads are and how to start one" do
    sign_in :jz

    get work_threads_url
    assert_response :success
    assert_select "details.work-threads__guide:not([open])" do
      assert_select "summary", text: "How to start a work thread"
      assert_select "li", text: /Track as work/
    end
    assert_select ".work-threads__empty", count: 0

    ChannelThread.where(room: @room).update_all(work_status: nil, work_owner_id: nil)

    get work_threads_url
    assert_response :success
    assert_select "details.work-threads__guide[open]"
    assert_select ".work-threads__empty", text: /No open work yet/

    get work_threads_url(state: "done")
    assert_select ".work-threads__empty", text: /No completed work yet/
  end

  test "owned-by-agents filter lists agent-owned work with the agent badge" do
    bot = User.create_bot!(name: "Filter Worker Bot")
    agent = bot.create_agent!(kind: :workspace, owner: users(:david))
    @room.memberships.grant_to(bot)
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "post_messages")

    agent_thread = ChannelThread.create!(room: @room, creator: @creator, name: "Agent owned work")
    ThreadMembership.join!(agent_thread, @creator)
    agent_thread.update_work!(actor: @creator, work_status: "in_progress", work_owner_id: bot.id)

    sign_in :jz

    get work_threads_url(state: "agents", format: :json)
    assert_response :success
    assert_equal [ agent_thread.id ], response.parsed_body.fetch("threads").pluck("id")

    get work_threads_url(state: "all", format: :json)
    assert_response :success
    assert_includes response.parsed_body.fetch("threads").pluck("id"), agent_thread.id

    get work_threads_url(state: "agents")
    assert_response :success
    assert_select ".work-threads__filter.active", text: "Owned by agents"
    assert_select ".work-threads__owner .agent-badge", text: "agent"
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
