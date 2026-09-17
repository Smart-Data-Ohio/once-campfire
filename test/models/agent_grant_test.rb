require "test_helper"

class AgentGrantTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:bender_agent)
    @room = rooms(:watercooler)
  end

  test "requires a known capability" do
    grant = AgentGrant.new(agent: @agent, granted_by: users(:david), capability: "launch_missiles")

    assert_not grant.valid?
    assert_includes grant.errors[:capability], "is not included in the list"
  end

  test "accepts every documented capability" do
    AgentGrant::CAPABILITIES.each do |capability|
      grant = AgentGrant.new(agent: @agent, room: @room, granted_by: users(:david), capability: capability)

      assert grant.valid?, "#{capability} should be valid: #{grant.errors.full_messages}"
    end
  end

  test "read, post, react, and external_action are enforced so far" do
    assert_equal %w[ read_messages post_messages react external_action ], AgentGrant::ENFORCED_CAPABILITIES
  end

  test "room is optional and means workspace-wide" do
    grant = AgentGrant.create!(agent: @agent, granted_by: users(:david), capability: "post_messages")

    assert_nil grant.room_id
    assert grant.workspace_wide?
    assert_not AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "react").workspace_wide?
  end

  test "duplicate active grants are rejected" do
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")
    duplicate = AgentGrant.new(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:capability], "has already been granted"
  end

  test "database rejects a second active workspace-wide grant for the same agent and capability" do
    AgentGrant.create!(agent: @agent, granted_by: users(:david), capability: "post_messages")
    duplicate = AgentGrant.new(agent: @agent, granted_by: users(:david), capability: "post_messages")

    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicate.save!(validate: false)
    end
  end

  test "database rejects a second active room grant for the same agent, room, and capability" do
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")
    duplicate = AgentGrant.new(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")

    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicate.save!(validate: false)
    end
  end

  test "same capability in another room or workspace-wide does not conflict" do
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")

    assert AgentGrant.new(agent: @agent, room: rooms(:designers), granted_by: users(:david), capability: "post_messages").valid?
    assert AgentGrant.new(agent: @agent, granted_by: users(:david), capability: "post_messages").valid?
  end

  test "re-granting after revocation is allowed" do
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages").revoke!

    assert AgentGrant.new(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages").valid?
  end

  test "revoke! timestamps and is idempotent" do
    grant = AgentGrant.create!(agent: @agent, granted_by: users(:david), capability: "post_messages")

    assert grant.active?
    assert_not grant.revoked?

    grant.revoke!

    assert grant.revoked?
    assert_not grant.active?
    assert_no_difference -> { grant.reload.revoked_at } do
      grant.revoke!
    end
  end

  test "active and revoked scopes" do
    active = AgentGrant.create!(agent: @agent, granted_by: users(:david), capability: "post_messages")
    revoked = AgentGrant.create!(agent: @agent, granted_by: users(:david), capability: "react")
    revoked.revoke!

    assert_equal [ active ], AgentGrant.active.to_a
    assert_equal [ revoked ], AgentGrant.revoked.to_a
  end
end
