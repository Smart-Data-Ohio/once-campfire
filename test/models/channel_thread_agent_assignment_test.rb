require "test_helper"

class ChannelThreadAgentAssignmentTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:watercooler)
    @manager = users(:david)
    @thread = ChannelThread.create!(room: @room, creator: @manager, name: "Agent work")
    ThreadMembership.join!(@thread, @manager)
    @thread.update_work!(actor: @manager, work_status: "planned")

    @bot = users(:bender)
    @agent = agents(:bender_agent)
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
  end

  test "an active member agent with post_messages is an eligible work owner" do
    grant!(@agent, "post_messages")

    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)

    assert_equal @bot.id, @thread.reload.work_owner_id
    assert @thread.work_owner_active?
  end

  test "a legacy agent keeps post eligibility through the fallback" do
    assert @agent.legacy_capabilities?

    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)

    assert_equal @bot.id, @thread.reload.work_owner_id
  end

  test "a suspended agent is rejected with a validation error" do
    grant!(@agent, "post_messages")
    @agent.suspend!

    error = assert_raises(ActiveRecord::RecordInvalid) do
      @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
    end

    assert_match "must be an active agent member", error.record.errors.full_messages.to_sentence
    assert_nil @thread.reload.work_owner_id
  end

  test "a non-member agent is rejected with a validation error" do
    memberships(:bender_watercooler).destroy!
    grant!(@agent, "post_messages")

    error = assert_raises(ActiveRecord::RecordInvalid) do
      @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
    end

    assert_match "must be an active agent member", error.record.errors.full_messages.to_sentence
    assert_nil @thread.reload.work_owner_id
  end

  test "an agent without post_messages is rejected with a validation error" do
    grant!(@agent, "read_messages")

    error = assert_raises(ActiveRecord::RecordInvalid) do
      @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
    end

    assert_match "must be an active agent member", error.record.errors.full_messages.to_sentence
    assert_nil @thread.reload.work_owner_id
  end

  test "a human outside the parent room keeps the human eligibility error" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      @thread.update_work!(actor: @manager, work_owner_id: users(:kevin).id)
    end

    assert_match "must be an active human member", error.record.errors.full_messages.to_sentence
    assert_nil @thread.reload.work_owner_id
  end

  test "a bot without an agent row is rejected with a validation error" do
    bot = User.create_bot!(name: "No Agent Bot")
    @room.memberships.grant_to(bot)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      @thread.update_work!(actor: @manager, work_owner_id: bot.id)
    end

    assert_match "must be an active agent member", error.record.errors.full_messages.to_sentence
    assert_nil @thread.reload.work_owner_id
  end

  test "suspending the agent or revoking its membership reads as an unavailable owner" do
    grant!(@agent, "post_messages")
    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
    assert @thread.reload.work_owner_active?

    other = create_agent_in(@room, name: "Suspended Owner Bot")
    grant!(other, "post_messages")
    other_thread = ChannelThread.create!(room: @room, creator: @manager, name: "Suspended work")
    ThreadMembership.join!(other_thread, @manager)
    other_thread.update_work!(actor: @manager, work_status: "planned", work_owner_id: other.user_id)
    assert other_thread.reload.work_owner_active?

    memberships(:bender_watercooler).destroy!
    assert_not @thread.reload.work_owner_active?
    assert_equal @bot.id, @thread.work_owner_id

    other.suspend!
    assert_not other_thread.reload.work_owner_active?
    assert_equal other.user_id, other_thread.work_owner_id
  end

  test "assignment writes one work_assigned row in the same transaction as the work event" do
    grant!(@agent, "post_messages")

    assert_difference -> { @thread.work_thread_events.count }, 1 do
      assert_difference -> { @agent.agent_events.where(event_type: "work_assigned").count }, 1 do
        @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
      end
    end

    event = @agent.agent_events.where(event_type: "work_assigned").last
    assert_equal "delivered", event.outcome
    assert_nil event.message_id
    assert_equal @room.id, event.room_id
    assert_equal @manager.id, event.actor_id
    assert_equal @thread.id, event.metadata["thread_id"]
    assert_equal "Agent work", event.metadata["title"]
    assert_equal "planned", event.metadata["work_status"]
    assert_equal "David", event.metadata["assigned_by"]
  end

  test "unassignment writes one work_unassigned row" do
    grant!(@agent, "post_messages")
    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)

    assert_difference -> { @agent.agent_events.where(event_type: "work_unassigned").count }, 1 do
      assert_no_difference -> { @agent.agent_events.where(event_type: "work_assigned").count } do
        @thread.update_work!(actor: @manager, work_owner_id: nil)
      end
    end

    event = @agent.agent_events.where(event_type: "work_unassigned").last
    assert_equal @room.id, event.room_id
    assert_equal @manager.id, event.actor_id
    assert_equal @thread.id, event.metadata["thread_id"]
  end

  test "unassignment after the agent left the room writes the ledger row but posts no webhook" do
    grant!(@agent, "post_messages")
    AgentGrant.create!(agent: @agent, room: nil, granted_by: @manager, capability: "read_messages")
    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
    @room.memberships.find_by!(user: @bot).destroy

    Agent::Delivery.expects(:post_work_webhook!).never

    assert_difference -> { @agent.agent_events.where(event_type: "work_unassigned").count }, 1 do
      @thread.update_work!(actor: @manager, work_owner_id: nil)
    end
  end

  test "assignment webhooks are posted after the outermost transaction commits" do
    grant!(@agent, "post_messages")
    grant!(@agent, "read_messages")
    baseline = ActiveRecord::Base.connection.open_transactions
    depth_at_post = nil
    posted_inside_outer_transaction = false

    Agent::Delivery.expects(:post_work_webhook!).with do |*|
      depth_at_post = ActiveRecord::Base.connection.open_transactions
      true
    end

    ChannelThread.transaction do
      @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
      posted_inside_outer_transaction = !depth_at_post.nil?
    end

    assert_not posted_inside_outer_transaction, "webhook must wait for the wrapping transaction"
    assert_equal baseline, depth_at_post
  end

  test "reassignment to a human writes work_unassigned and no work_assigned" do
    grant!(@agent, "post_messages")
    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)

    assert_difference -> { @agent.agent_events.where(event_type: "work_unassigned").count }, 1 do
      @thread.update_work!(actor: @manager, work_owner_id: users(:jason).id)
    end

    assert_equal users(:jason).id, @thread.reload.work_owner_id
  end

  test "reassignment between agents notifies both" do
    grant!(@agent, "post_messages")
    other = create_agent_in(@room, name: "Second Owner Bot")
    grant!(other, "post_messages")
    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)

    assert_difference -> { @agent.agent_events.where(event_type: "work_unassigned").count }, 1 do
      assert_difference -> { other.agent_events.where(event_type: "work_assigned").count }, 1 do
        @thread.update_work!(actor: @manager, work_owner_id: other.user_id)
      end
    end
  end

  test "status-only changes and human-to-human assignment write no agent rows" do
    grant!(@agent, "post_messages")
    @thread.update_work!(actor: @manager, work_owner_id: users(:jason).id)

    assert_no_difference -> { AgentEvent.where(event_type: %w[ work_assigned work_unassigned ]).count } do
      @thread.update_work!(actor: @manager, work_status: "in_progress")
      @thread.update_work!(actor: @manager, work_owner_id: users(:david).id)
    end

    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
    assert_no_difference -> { AgentEvent.where(event_type: %w[ work_assigned work_unassigned ]).count } do
      @thread.update_work!(actor: @manager, work_status: "blocked")
    end
  end

  test "assignment rows roll back when the work event fails" do
    grant!(@agent, "post_messages")
    WorkThreadEvent.stubs(:create_for_change!).raises(RuntimeError, "boom")

    assert_raises(RuntimeError) do
      @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
    end

    assert_nil @thread.reload.work_owner_id
    assert_empty @agent.agent_events.where(event_type: "work_assigned")
  end

  test "the work event rolls back when the assignment row fails" do
    grant!(@agent, "post_messages")
    @thread.stubs(:record_work_assignment_events!).raises(RuntimeError, "boom")

    assert_raises(RuntimeError) do
      @thread.update_work!(actor: @manager, work_owner_id: @bot.id)
    end

    assert_nil @thread.reload.work_owner_id
    assert_equal 1, @thread.work_thread_events.count
  end

  test "an agent status update records a work event with the note" do
    grant!(@agent, "post_messages")
    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)

    @thread.update_work_by_agent!(agent: @agent, work_status: "in_progress", note: "Digging in")

    assert_equal "in_progress", @thread.reload.work_status
    event = @thread.work_thread_events.ordered.first
    assert_equal "work_update", event.event_type
    assert_equal "planned", event.from_status
    assert_equal "in_progress", event.to_status
    assert_equal @bot.id, event.actor_id
    assert_equal "Digging in", event.note
    assert_equal "Digging in", event.metadata["note"]
  end

  test "an agent status update reaches the inbox through the human path" do
    room = rooms(:designers)
    creator = users(:jz)
    recipient = users(:david)
    bot = User.create_bot!(name: "Inbox Worker Bot")
    agent = bot.create_agent!(kind: :workspace, owner: users(:david))
    room.memberships.grant_to(bot)
    grant_in!(agent, room, "post_messages")

    thread = ChannelThread.create!(room: room, creator: creator, name: "Inbox agent work")
    ThreadMembership.join!(thread, creator)
    ThreadMembership.join!(thread, recipient).update!(involvement: "everything")
    thread.update_work!(actor: creator, work_status: "planned", work_owner_id: bot.id)

    thread.update_work_by_agent!(agent: agent, work_status: "in_progress", note: "On it")

    event = thread.work_thread_events.ordered.first
    assert_equal "work_update", ActivityItem.find_by!(user: recipient, source: event).event_type
    assert_equal "work_update", ActivityItem.find_by!(user: creator, source: event).event_type
    assert_not ActivityItem.exists?(user: bot, source: event)
  end

  test "an agent cannot move work it does not own" do
    grant!(@agent, "post_messages")
    @thread.update_work!(actor: @manager, work_owner_id: users(:jason).id)

    assert_raises(ActiveRecord::RecordNotFound) do
      @thread.update_work_by_agent!(agent: @agent, work_status: "in_progress")
    end

    assert_equal "planned", @thread.reload.work_status
  end

  test "an agent status update rejects unknown statuses and long notes" do
    grant!(@agent, "post_messages")
    @thread.update_work!(actor: @manager, work_owner_id: @bot.id)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      @thread.update_work_by_agent!(agent: @agent, work_status: "shipped")
    end
    assert_match "is invalid", error.record.errors.full_messages.to_sentence

    error = assert_raises(ActiveRecord::RecordInvalid) do
      @thread.update_work_by_agent!(agent: @agent, work_status: "in_progress", note: "x" * 501)
    end
    assert_match "too long", error.record.errors.full_messages.to_sentence

    assert_equal "planned", @thread.reload.work_status
    assert_equal 2, @thread.work_thread_events.count
  end

  private
    def grant!(agent, capability)
      AgentGrant.create!(agent: agent, room: @room, granted_by: @manager, capability: capability)
    end

    def grant_in!(agent, room, capability)
      AgentGrant.create!(agent: agent, room: room, granted_by: @manager, capability: capability)
    end

    def create_agent_in(room, name:)
      bot = User.create_bot!(name: name)
      agent = bot.create_agent!(kind: :workspace, owner: @manager)
      room.memberships.grant_to(bot)
      agent
    end
end
