require "test_helper"

class ActivityItemApprovalsTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:bender_agent)
    @room = rooms(:watercooler)
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
  end

  test "approval inbox item is accessible to the owner and admins only" do
    @agent.update!(owner: users(:kevin))
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    owner_item = ActivityItem.find_by!(user: users(:kevin), source: approval)
    david_item = ActivityItem.find_by!(user: users(:david), source: approval)
    jason_item = ActivityItem.find_by!(user: users(:jason), source: approval)

    assert_includes ActivityItem.accessible_to(users(:kevin)), owner_item
    assert_includes ActivityItem.accessible_to(users(:david)), david_item
    assert_includes ActivityItem.accessible_to(users(:jason)), jason_item

    assert_not ActivityItem.accessible_to(users(:jz)).exists?(id: david_item.id)
    assert_empty ActivityItem.accessible_to(users(:jz)).where(source: approval)
  end

  test "workspace agent without an owner is decided by administrators only" do
    @agent.update_columns(owner_id: nil)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    assert_equal 2, ActivityItem.where(source: approval).count
    assert_includes ActivityItem.accessible_to(users(:david)), ActivityItem.find_by!(user: users(:david), source: approval)
    assert_empty ActivityItem.accessible_to(users(:kevin)).where(source: approval)
  end

  test "approval inbox item disappears after the agent user is deactivated" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    item = ActivityItem.find_by!(user: users(:david), source: approval)
    assert_includes ActivityItem.accessible_to(users(:david)), item

    @agent.user.update!(status: :deactivated)

    assert_not ActivityItem.accessible_to(users(:david)).exists?(item.id)
  end

  test "approval inbox item disappears when the owner changes" do
    @agent.update!(owner: users(:kevin))
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    owner_item = ActivityItem.find_by!(user: users(:kevin), source: approval)
    assert_includes ActivityItem.accessible_to(users(:kevin)), owner_item

    @agent.update!(owner: users(:jz))

    assert_not ActivityItem.accessible_to(users(:kevin)).exists?(owner_item.id)
  end

  test "non-deciders never receive an inbox item" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    assert_nil ActivityItem.find_by(user: users(:kevin), source: approval)
    assert_nil ActivityItem.find_by(user: users(:jz), source: approval)
  end
end
