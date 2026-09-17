require "test_helper"

class AgentRevocationTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:bender_agent)
    @room = rooms(:watercooler)
  end

  test "removing a membership revokes that agent's grants in that room only" do
    room_grant = grant!(capability: "post_messages", room: @room)
    other_room_grant = grant!(capability: "post_messages", room: rooms(:designers))

    memberships(:bender_watercooler).destroy!

    assert room_grant.reload.revoked?
    assert_not other_room_grant.reload.revoked?
    assert_not @agent.can?(:post_messages, @room)
  end

  test "workspace-wide grants survive membership removal" do
    workspace_grant = grant!(capability: "post_messages")

    memberships(:bender_watercooler).destroy!

    assert_not workspace_grant.reload.revoked?
  end

  test "membership revocation persists in the same transaction as the removal" do
    grant = grant!(capability: "post_messages", room: @room)

    Membership.transaction do
      memberships(:bender_watercooler).destroy!
      assert grant.reload.revoked?
      raise ActiveRecord::Rollback
    end

    assert_not grant.reload.revoked?
    assert Membership.exists?(user: users(:bender), room: @room)
  end

  test "destroying a room revokes its grants and forbids the next post" do
    grant = grant!(capability: "post_messages", room: @room)
    workspace_grant = grant!(capability: "react")

    @room.destroy!

    assert grant.reload.revoked?
    assert_not workspace_grant.reload.revoked?
    assert_not @agent.can?(:post_messages, @room)
  end

  test "suspending an agent revokes all of its grants immediately" do
    room_grant = grant!(capability: "post_messages", room: @room)
    workspace_grant = grant!(capability: "react")

    @agent.suspend!

    assert room_grant.reload.revoked?
    assert workspace_grant.reload.revoked?
    assert_not @agent.can?(:post_messages, @room)
    assert_not @agent.can?(:react, @room)
  end

  test "deactivating the agent user revokes all of its grants" do
    room_grant = grant!(capability: "post_messages", room: @room)
    workspace_grant = grant!(capability: "react")

    users(:bender).deactivate

    assert room_grant.reload.revoked?
    assert workspace_grant.reload.revoked?
    assert_not @agent.reload.can?(:post_messages, @room)
  end

  test "banning the agent user revokes all of its grants" do
    room_grant = grant!(capability: "post_messages", room: @room)

    users(:bender).ban

    assert room_grant.reload.revoked?
    assert_not @agent.reload.can?(:post_messages, @room)
  end

  test "destroying the agent user revokes all of its grants" do
    grant = grant!(capability: "post_messages", room: @room)

    users(:bender).destroy!

    assert grant.reload.revoked?
  end

  private
    def grant!(capability:, room: nil)
      AgentGrant.create!(agent: @agent, room: room, granted_by: users(:david), capability: capability)
    end
end
