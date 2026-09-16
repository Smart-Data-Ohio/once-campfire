require "test_helper"

class AgentTest < ActiveSupport::TestCase
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
end
