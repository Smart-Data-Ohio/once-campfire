require "test_helper"

class AgentEventTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:bender_agent)
    @room = rooms(:watercooler)
  end

  test "requires a known event type" do
    event = AgentEvent.new(agent: @agent, event_type: "launch_missiles", outcome: "pending")

    assert_not event.valid?
    assert_includes event.errors[:event_type], "is not included in the list"
  end

  test "accepts every documented event type" do
    AgentEvent::EVENT_TYPES.each do |event_type|
      event = AgentEvent.new(agent: @agent, event_type: event_type, outcome: "pending")

      assert event.valid?, "#{event_type} should be valid: #{event.errors.full_messages}"
    end
  end

  test "requires a known outcome" do
    event = AgentEvent.new(agent: @agent, event_type: "mention", outcome: "bogus")

    assert_not event.valid?
    assert_includes event.errors[:outcome], "is not included in the list"
  end

  test "room, message, credential, and actor are optional" do
    event = AgentEvent.create!(agent: @agent, event_type: "mention", outcome: "pending")

    assert_nil event.room_id
    assert_nil event.message_id
  end

  test "deliverable scope covers message types, approval decisions, work assignments, and github completions" do
    %w[ mention direct_message reply approval_decided work_assigned work_unassigned github_action_completed ].each do |event_type|
      AgentEvent.create!(agent: @agent, event_type: event_type, outcome: "pending")
    end
    %w[ delivery_suppressed_rate_limit delivery_suppressed_hop_limit delivery_suppressed_revoked posted ].each do |event_type|
      AgentEvent.create!(agent: @agent, event_type: event_type, outcome: "suppressed")
    end

    assert_equal %w[ approval_decided direct_message github_action_completed mention reply work_assigned work_unassigned ].sort,
      @agent.agent_events.deliverable.pluck(:event_type).sort
  end

  test "message_deliverable scope excludes approval decisions, work assignments, and github completions" do
    %w[ mention direct_message reply approval_decided work_assigned work_unassigned github_action_completed ].each do |event_type|
      AgentEvent.create!(agent: @agent, event_type: event_type, outcome: "pending")
    end

    assert_equal %w[ direct_message mention reply ].sort,
      @agent.agent_events.message_deliverable.pluck(:event_type).sort
  end

  test "hop defaults to zero and reads metadata" do
    assert_equal 0, AgentEvent.new.hop
    assert_equal 2, AgentEvent.new(metadata: { "hop" => 2 }).hop
  end

  test "acknowledged! is idempotent" do
    event = AgentEvent.create!(agent: @agent, event_type: "mention", outcome: "delivered")

    event.acknowledged!
    assert_equal "acknowledged", event.reload.outcome

    event.acknowledged!
    assert_equal "acknowledged", event.reload.outcome
  end

  test "destroying the agent removes its events" do
    AgentEvent.create!(agent: @agent, event_type: "mention", outcome: "pending")

    @agent.destroy!

    assert_empty AgentEvent.where(agent_id: @agent.id)
  end

  test "agent exposes its events" do
    event = AgentEvent.create!(agent: @agent, event_type: "mention", outcome: "pending")

    assert_includes @agent.agent_events, event
  end
end
