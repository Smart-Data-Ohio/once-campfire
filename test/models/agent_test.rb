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
end
