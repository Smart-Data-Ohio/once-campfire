require "application_system_test_case"

class AgentApprovalsTest < ApplicationSystemTestCase
  setup do
    @agent = agents(:bender_agent)
    @room = rooms(:watercooler)
    @approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship the release")
    sign_in "david@37signals.com"
  end

  test "owner sees the request in the inbox, approves it, and the agent is notified" do
    visit activity_items_url

    assert_selector "#activity-inbox-title", text: "Activity inbox"
    item = ActivityItem.find_by!(user: users(:david), source: @approval)

    within "##{dom_id(item)}" do
      assert_text "Approval request"
      assert_text "Bender Bot"
      assert_text "Ship the release"
      assert_text "Expires in"
      click_button "Approve"
    end

    # Deciding marks the item handled, so it leaves the unread view.
    assert_no_selector "##{dom_id(item)}", wait: 10
    assert_equal "approved", @approval.reload.status

    visit activity_items_url(status: "handled")
    assert_selector "##{dom_id(item)}", text: "Approved by David", wait: 10

    event = @agent.agent_events.where(event_type: "approval_decided").last
    assert event, "expected an approval_decided ledger row"
    assert_equal @approval.id, event.metadata["approval_id"]
    assert_equal "approved", event.metadata["status"]
  end
end
