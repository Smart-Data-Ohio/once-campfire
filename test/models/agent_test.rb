require "test_helper"

class AgentTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  test "kind defaults to personal" do
    assert_equal "personal", Agent.new.kind
    assert Agent.new.personal?
  end

  test "personal requires an owner on create" do
    agent = Agent.new(user: users(:bender), kind: :personal, owner: nil)
    assert_not agent.valid?
    assert_includes agent.errors[:owner_id], "can't be blank"
  end

  test "personal requires an owner on update" do
    agent = agents(:bender_agent)
    agent.update!(kind: :personal)

    agent.owner = nil
    assert_not agent.valid?
  end

  test "workspace requires an owner on create" do
    agent = Agent.new(user: users(:bender), kind: :workspace, owner: nil)
    assert_not agent.valid?
    assert_includes agent.errors[:owner_id], "can't be blank"
  end

  test "ownerless workspace rows from the backfill stay valid on update" do
    agent = agents(:bender_agent)
    agent.update_columns(owner_id: nil)

    assert agent.reload.valid?
    assert agent.update(description: "Backfilled bot")
  end

  test "user is required and unique" do
    assert_not Agent.new(kind: :workspace, owner: users(:david)).valid?

    duplicate = Agent.new(user: users(:bender), kind: :workspace, owner: users(:david))
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "belongs to bot user and owner" do
    agent = agents(:bender_agent)

    assert_equal users(:bender), agent.user
    assert_equal users(:david), agent.owner
    assert_equal agent, users(:bender).agent
  end

  test "destroying the bot user removes its agent" do
    users(:bender).destroy!

    assert_not Agent.exists?(user_id: users(:bender).id)
  end

  test "active when not suspended and user is active" do
    assert agents(:bender_agent).active?
  end

  test "inactive when suspended" do
    agent = agents(:bender_agent)
    agent.update!(suspended_at: Time.current)

    assert_not agent.active?
  end

  test "inactive when user is deactivated" do
    users(:bender).update!(status: :deactivated)

    assert_not agents(:bender_agent).reload.active?
  end

  test "legacy capabilities when no grants have ever existed" do
    assert agents(:bender_agent).legacy_capabilities?
  end

  test "no legacy capabilities once any grant exists" do
    AgentGrant.create!(agent: agents(:bender_agent), granted_by: users(:david), capability: "post_messages")

    assert_not agents(:bender_agent).legacy_capabilities?
  end

  test "revoking the last grant does not restore the legacy fallback" do
    AgentGrant.create!(agent: agents(:bender_agent), granted_by: users(:david), capability: "post_messages").revoke!

    agent = agents(:bender_agent)
    assert_not agent.legacy_capabilities?
    assert_not agent.can?(:post_messages, rooms(:watercooler))
  end

  test "legacy agent keeps read, post, and react but nothing else" do
    agent = agents(:bender_agent)

    assert agent.can?(:read_messages, rooms(:watercooler))
    assert agent.can?(:post_messages, rooms(:watercooler))
    assert agent.can?(:react, rooms(:watercooler))
    assert_not agent.can?(:manage_threads, rooms(:watercooler))
    assert_not agent.can?(:external_action, rooms(:watercooler))
  end

  test "room grant authorizes only that room" do
    agent = agents(:bender_agent)
    AgentGrant.create!(agent: agent, room: rooms(:watercooler), granted_by: users(:david), capability: "post_messages")

    assert agent.can?(:post_messages, rooms(:watercooler))
    assert_not agent.can?(:post_messages, rooms(:designers))
    assert_not agent.can?(:react, rooms(:watercooler))
  end

  test "workspace-wide grant authorizes every room" do
    agent = agents(:bender_agent)
    AgentGrant.create!(agent: agent, granted_by: users(:david), capability: "post_messages")

    assert agent.can?(:post_messages, rooms(:watercooler))
    assert agent.can?(:post_messages, rooms(:designers))
  end

  test "revoked grants do not authorize" do
    agent = agents(:bender_agent)
    AgentGrant.create!(agent: agent, room: rooms(:watercooler), granted_by: users(:david), capability: "post_messages").revoke!

    assert_not agent.can?(:post_messages, rooms(:watercooler))
  end

  test "suspended agent cannot do anything, even with legacy fallback" do
    agent = agents(:bender_agent)
    agent.suspend!

    assert_not agent.can?(:post_messages, rooms(:watercooler))
    assert_not agent.can?(:read_messages, rooms(:watercooler))
  end

  test "unknown capabilities are denied" do
    assert_not agents(:bender_agent).can?(:launch_missiles, rooms(:watercooler))
  end

  test "status defaults to idle" do
    assert_equal "idle", Agent.new.status
    assert_equal "idle", agents(:bender_agent).status
  end

  test "status accepts the vocabulary and rejects anything else" do
    agent = agents(:bender_agent)

    Agent::STATUSES.each do |status|
      agent.status = status
      assert agent.valid?, "#{status} should be valid"
    end

    agent.status = "napping"
    assert_not agent.valid?
    assert_includes agent.errors[:status], "is not included in the list"
  end

  test "status note allows 200 characters at most" do
    agent = agents(:bender_agent)

    agent.status_note = "x" * 200
    assert agent.valid?

    agent.status_note = "x" * 201
    assert_not agent.valid?
  end

  test "description allows 500 characters at most" do
    agent = agents(:bender_agent)

    agent.description = "x" * 500
    assert agent.valid?

    agent.description = "x" * 501
    assert_not agent.valid?
  end

  test "status_changed_at starts blank and is stamped on status change only" do
    bot = User.create_bot!(name: "Stamp Bot")
    agent = bot.create_agent!(kind: :workspace, owner: users(:david))
    assert_nil agent.status_changed_at

    agent.update!(status_note: "just a note")
    assert_nil agent.reload.status_changed_at

    agent.update!(provider: "Acme")
    assert_nil agent.reload.status_changed_at

    assert_changes -> { agent.reload.status_changed_at }, from: nil do
      agent.update!(status: "working")
    end
  end

  test "touch_last_seen_at throttles to once per minute" do
    agent = agents(:bender_agent)
    assert_nil agent.last_seen_at

    agent.touch_last_seen!
    first_touch = agent.reload.last_seen_at
    assert first_touch.present?

    agent.touch_last_seen!
    assert_equal first_touch, agent.reload.last_seen_at

    agent.update_column(:last_seen_at, 61.seconds.ago)
    agent.touch_last_seen!
    assert agent.reload.last_seen_at > first_touch
  end

  test "kind description covers personal, workspace, and ownerless agents" do
    personal = users(:bender).agent
    personal.update!(kind: :personal, owner: users(:kevin))
    assert_equal "Personal agent of Kevin", personal.kind_description

    personal.update!(kind: :workspace, owner: users(:kevin))
    assert_equal "Workspace agent, managed by Kevin", personal.kind_description

    personal.update_columns(owner_id: nil)
    assert_equal "no owner recorded", personal.reload.kind_description
  end

  test "grants summary reports legacy access when no grants were ever recorded" do
    assert_equal "legacy access (no grants recorded)", agents(:bender_agent).grants_summary
  end

  test "grants summary counts room grants and flags workspace-wide grants" do
    agent = agents(:bender_agent)
    david = users(:david)

    AgentGrant.create!(agent: agent, room: rooms(:watercooler), granted_by: david, capability: "post_messages")
    AgentGrant.create!(agent: agent, room: rooms(:designers), granted_by: david, capability: "post_messages")
    AgentGrant.create!(agent: agent, room: rooms(:hq), granted_by: david, capability: "post_messages")
    AgentGrant.create!(agent: agent, granted_by: david, capability: "read_messages")

    assert_equal "post_messages in 3 rooms, read_messages workspace-wide", agent.grants_summary
  end

  test "grants summary omits capabilities with no active grant" do
    agent = agents(:bender_agent)

    AgentGrant.create!(agent: agent, room: rooms(:watercooler), granted_by: users(:david), capability: "react").revoke!
    AgentGrant.create!(agent: agent, granted_by: users(:david), capability: "read_messages")

    assert_equal "read_messages workspace-wide", agent.grants_summary
  end

  test "grants summary reports no active grants once everything is revoked" do
    agent = agents(:bender_agent)

    AgentGrant.create!(agent: agent, granted_by: users(:david), capability: "read_messages").revoke!

    assert_equal "no active grants", agent.grants_summary
  end

  test "activity summary counts the last 24 hours from the ledger" do
    agent = agents(:bender_agent)
    room = rooms(:watercooler)
    message = room.messages.create!(creator: users(:david), body: "hey", client_message_id: "activity-summary")

    agent.agent_events.create!(event_type: "mention", room: room, message: message, outcome: "delivered")
    agent.agent_events.create!(event_type: "reply", room: room, message: message, outcome: "acknowledged")
    agent.agent_events.create!(event_type: "posted", room: room, message: message, outcome: "delivered")
    agent.agent_events.create!(event_type: "delivery_suppressed_rate_limit", room: room, message: message, outcome: "suppressed")
    agent.agent_events.create!(event_type: "mention", room: room, message: message, outcome: "delivered", created_at: 25.hours.ago)

    assert_equal "1 delivered, 1 acknowledged, 1 posted, 1 suppressed", agent.activity_summary
  end

  test "for_directory lists active first, excludes deactivated users" do
    active = agents(:bender_agent)
    suspended_bot = User.create_bot!(name: "Zed Suspended")
    suspended = suspended_bot.create_agent!(kind: :workspace, owner: users(:david))
    suspended.suspend!
    gone_bot = User.create_bot!(name: "Aaron Gone")
    gone_bot.create_agent!(kind: :workspace, owner: users(:david))
    gone_bot.deactivate

    assert_equal [ active, suspended ], Agent.for_directory
  end

  test "status change broadcasts badge and directory row replaces to agents:all" do
    agent = agents(:bender_agent)

    assert_broadcasts AgentsChannel::STREAM_NAME, 2 do
      agent.update!(status: "working", status_note: "on it")
    end

    streams = ActionCable.server.pubsub.broadcasts(AgentsChannel::STREAM_NAME).collect { |broadcast| JSON.parse(broadcast) }.join
    assert_match %(target="status_badge_agent_#{agent.id}"), streams
    assert_match "Working", streams
    assert_match "on it", streams
    assert_match %(target="directory_row_agent_#{agent.id}"), streams
    assert_match "Bender Bot", streams
  end

  test "status broadcasts carry no credentials or grants" do
    agent = agents(:bender_agent)
    AgentGrant.create!(agent: agent, granted_by: users(:david), capability: "post_messages")

    agent.update!(status: "failed")

    streams = ActionCable.server.pubsub.broadcasts(AgentsChannel::STREAM_NAME).join
    assert_no_match agent_credentials(:bender_main).token_digest, streams
    assert_no_match "post_messages", streams
  end

  test "note-only change still broadcasts the badge" do
    agent = agents(:bender_agent)

    assert_broadcasts AgentsChannel::STREAM_NAME, 2 do
      agent.update!(status_note: "still here")
    end
  end

  test "touch_last_seen_at writes at most once when the throttle races" do
    agent = agents(:bender_agent)
    agent.update_column(:last_seen_at, nil)

    # Simulate a concurrent request that won the race after this instance
    # loaded a nil value: the conditional UPDATE must see the fresh row.
    Agent.where(id: agent.id).update_all(last_seen_at: 10.seconds.ago)
    winner = Agent.find(agent.id).last_seen_at

    agent.touch_last_seen!
    assert_equal winner.to_i, agent.reload.last_seen_at.to_i
  end

  test "last_seen_at touch alone broadcasts nothing" do
    agent = agents(:bender_agent)

    assert_broadcasts AgentsChannel::STREAM_NAME, 0 do
      agent.touch_last_seen!
    end
  end

  test "unrelated updates broadcast nothing" do
    agent = agents(:bender_agent)

    assert_broadcasts AgentsChannel::STREAM_NAME, 0 do
      agent.update!(provider: "Acme", runtime: "CLI", description: "hi")
    end
  end
end
