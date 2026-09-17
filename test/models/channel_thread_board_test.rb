require "test_helper"

class ChannelThreadBoardTest < ActiveSupport::TestCase
  setup do
    @room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) },
      users: [ users(:david), users(:jz), users(:kevin) ])
    @creator = users(:jz)
  end

  test "board posts require work tracking while channel threads stay optional" do
    post = ChannelThread.new(room: @room, creator: @creator, name: "Untracked")
    assert_not post.valid?
    assert_includes post.errors[:work_status], "must be tracked in a board"

    post.work_status = "planned"
    assert post.valid?

    ordinary = ChannelThread.new(room: rooms(:designers), creator: @creator, name: "Discussion")
    assert ordinary.valid?

    tracked = ChannelThread.create!(room: @room, creator: @creator, name: "Tracked", work_status: "planned")
    assert_raises ActiveRecord::RecordInvalid do
      tracked.update!(work_status: nil)
    end
  end

  test "close_stale_in skips board posts but still archives channel threads" do
    post = ChannelThread.create!(room: @room, creator: @creator, name: "Old post", work_status: "planned")
    post.update_columns(last_activity_at: 2.hours.ago, auto_archive_after_minutes: 60)
    thread = ChannelThread.create!(room: rooms(:designers), creator: @creator, name: "Old thread")
    thread.update_columns(last_activity_at: 2.hours.ago, auto_archive_after_minutes: 60)

    ChannelThread.close_stale_in

    assert_predicate post.reload, :active?
    assert_predicate thread.reload, :closed?

    ChannelThread.close_stale_in(room: @room)
    assert_predicate post.reload, :active?
  end

  test "tag writer normalises names" do
    post = ChannelThread.new(room: @room, creator: @creator, name: "Tagged", work_status: "planned")
    post.tag_names = "Bug, bug ,, API-v2"

    assert_equal %w[ bug api-v2 ], post.tag_names

    post.save!
    assert_equal %w[ api-v2 bug ], post.reload.tag_names
  end

  test "tag count, length, and format are validated without destroying existing tags" do
    post = ChannelThread.create!(room: @room, creator: @creator, name: "Tagged", work_status: "planned")
    post.tag_names = "bug"
    post.save!

    post.tag_names = "one, two, three, four, five, six"
    assert_not post.valid?
    assert_includes post.errors[:tags], "are limited to 5 per post"

    post.tag_names = "a" * 31
    assert_not post.valid?
    assert_includes post.errors[:tags], "must be at most 30 characters"

    post.tag_names = "needs work!"
    assert_not post.valid?
    assert_includes post.errors[:tags], "use lowercase letters, digits, and hyphens"

    assert_equal %w[ bug ], post.reload.tag_names
  end

  test "tag edits replace the previous set" do
    post = ChannelThread.create!(room: @room, creator: @creator, name: "Tagged", work_status: "planned")
    post.tag_names = "bug, api"
    post.save!

    post.tag_names = "api, docs"
    post.save!

    assert_equal %w[ api docs ], post.reload.tag_names

    post.tag_names = ""
    post.save!
    assert_empty post.reload.tag_names
  end

  test "result edits record a result_updated event with an excerpt" do
    post = ChannelThread.create!(room: @room, creator: @creator, name: "Outcome",
      work_status: "in_progress", work_owner_id: users(:kevin).id)
    ThreadMembership.join!(post, @creator)

    assert_difference -> { WorkThreadEvent.count }, 1 do
      post.update_result!(actor: users(:david), markdown: "## Shipped\n\nIt works.")
    end

    event = post.work_thread_events.ordered.first
    assert_equal "result_updated", event.event_type
    assert_equal users(:david).id, event.actor_id
    assert_equal "## Shipped\n\nIt works.", event.metadata["excerpt"]
    assert_equal users(:kevin).id, event.to_owner_id
    assert_equal "in_progress", event.to_status

    post.reload
    assert_equal "## Shipped\n\nIt works.", post.result_markdown
    assert_not_nil post.result_updated_at
    assert_equal users(:david).id, post.result_updated_by_id

    long_result = "x" * 250
    post.update_result!(actor: users(:david), markdown: long_result)
    assert_equal "x" * 200, post.work_thread_events.ordered.first.metadata["excerpt"]
  end

  test "result edits notify the creator and owner other than the actor" do
    bystander = users(:kevin)
    post = ChannelThread.create!(room: @room, creator: @creator, name: "Outcome",
      work_status: "planned", work_owner_id: users(:david).id)
    ThreadMembership.join!(post, @creator)
    ThreadMembership.join!(post, bystander).update!(involvement: "everything")

    assert_difference -> { ActivityItem.where(user: @creator, event_type: "work_update").count }, 1 do
      assert_no_difference -> { ActivityItem.where(user: bystander).count } do
        assert_no_difference -> { ActivityItem.where(user: users(:david)).count } do
          post.update_result!(actor: users(:david), markdown: "Done.")
        end
      end
    end

    item = ActivityItem.find_by!(user: @creator, event_type: "work_update")
    assert_equal "result_updated", item.source.event_type

    post.update_result!(actor: @creator, markdown: "Done, really.")
    assert_equal 1, ActivityItem.where(user: users(:david), event_type: "work_update").count
  end

  test "result edits require status permission and respect the length limit" do
    post = ChannelThread.create!(room: @room, creator: @creator, name: "Outcome", work_status: "planned")
    ThreadMembership.join!(post, @creator)

    assert_raises ChannelThread::WorkUpdateForbidden do
      post.update_result!(actor: users(:kevin), markdown: "Nope.")
    end
    assert_nil post.reload.result_markdown

    post.errors.clear
    assert_raises ActiveRecord::RecordInvalid do
      post.update_result!(actor: @creator, markdown: "x" * 20_001)
    end

    post.update_result!(actor: @creator, markdown: "Same.")
    assert_no_difference -> { WorkThreadEvent.count } do
      post.update_result!(actor: @creator, markdown: "Same.")
    end
  end

  test "run_url accepts only short https URLs" do
    post = ChannelThread.create!(room: @room, creator: @creator, name: "Linked", work_status: "planned")

    post.run_url = "http://example.test/run/1"
    assert_not post.valid?

    post.run_url = "https://example.test/#{"x" * 500}"
    assert_not post.valid?

    post.run_url = "https://example.test/run/1"
    assert post.valid?
    assert post.run_link?

    post.run_url = nil
    assert post.valid?
    assert_not post.run_link?
  end

  test "board post query filters by status, owner, and tag" do
    open_post = ChannelThread.create!(room: @room, creator: @creator, name: "Open",
      work_status: "planned", work_owner_id: users(:kevin).id)
    open_post.tag_names = "bug"
    open_post.save!
    done_post = ChannelThread.create!(room: @room, creator: @creator, name: "Done",
      work_status: "done", work_owner_id: @creator.id)

    assert_equal [ open_post.id ], ChannelThread.board_posts_for(@room).pluck(:id)
    assert_equal [ done_post.id ], ChannelThread.board_posts_for(@room, status: "done").pluck(:id)
    assert_equal 2, ChannelThread.board_posts_for(@room, status: "all").count
    assert_equal [ done_post.id ], ChannelThread.board_posts_for(@room, status: "all", owner: "me", viewer: @creator).pluck(:id)
    assert_equal [ open_post.id ], ChannelThread.board_posts_for(@room, status: "all", owner: users(:kevin).id.to_s).pluck(:id)
    assert_equal [ open_post.id ], ChannelThread.board_posts_for(@room, status: "all", tag: "Bug").pluck(:id)
    assert_empty ChannelThread.board_posts_for(@room, status: "all", tag: "missing")

    assert_equal({ "bug" => 1 }, ChannelThread.board_tag_counts(@room))
  end

  test "agent owner filter matches update-work eligibility" do
    agent_user = User.create_bot!(name: "Board Worker")
    agent = agent_user.create_agent!(kind: :workspace, owner: users(:david))
    @room.memberships.grant_to(agent_user)
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "post_messages")

    post = ChannelThread.create!(room: @room, creator: @creator, name: "Agent post", work_status: "planned")
    post.update_work!(actor: @creator, work_owner_id: agent_user.id)

    assert_equal [ post.id ], ChannelThread.board_posts_for(@room, owner: "agents").pluck(:id)

    humans, agents = post.work_owner_candidates
    assert_includes humans.map(&:id), users(:kevin).id
    assert_includes agents.map(&:id), agent_user.id
  end
end
