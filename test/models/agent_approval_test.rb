require "test_helper"

class AgentApprovalTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:bender_agent)
    @room = rooms(:watercooler)
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
  end

  test "requires action, summary, and expires_at with valid formats" do
    approval = AgentApproval.new(agent: @agent, action: "", summary: "", expires_at: nil)
    approval.valid?
    # expires_at gets a default, so only action/summary fail here
    assert_includes approval.errors[:action], "can't be blank"
    assert_includes approval.errors[:summary], "can't be blank"
  end

  test "rejects actions outside the allowed charset or length" do
    approval = AgentApproval.new(agent: @agent, action: "Deploy!", summary: "ok")
    assert_not approval.valid?
    assert_includes approval.errors[:action], "is invalid"

    approval.action = "a" * 61
    assert_not approval.valid?
    assert approval.errors[:action].any? { |message| message =~ /too long/ }

    approval.action = "deploy.prod_1-ok"
    assert approval.valid?, approval.errors.full_messages.to_sentence
  end

  test "rejects summaries over 500 characters" do
    approval = AgentApproval.new(agent: @agent, action: "deploy", summary: "x" * 501)
    assert_not approval.valid?
    assert approval.errors[:summary].any? { |message| message =~ /too long/ }
  end

  test "rejects payloads over 4 KB" do
    approval = AgentApproval.new(agent: @agent, action: "deploy", summary: "ok", payload: "x" * (4.kilobytes + 1))
    assert_not approval.valid?
    assert_includes approval.errors[:payload], "is too large (maximum is 4 KB)"
  end

  test "defaults expires_at to 24 hours" do
    approval = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ship it")
    assert_in_delta 24.hours.from_now.to_i, approval.expires_at.to_i, 60
  end

  test "rejects expiry windows outside 5 minutes to 7 days" do
    too_soon = AgentApproval.new(agent: @agent, action: "deploy", summary: "ok", expires_at: 2.minutes.from_now)
    assert_not too_soon.valid?
    assert_includes too_soon.errors[:expires_at], "must be at least 5 minutes from now"

    too_late = AgentApproval.new(agent: @agent, action: "deploy", summary: "ok", expires_at: 8.days.from_now)
    assert_not too_late.valid?
    assert_includes too_late.errors[:expires_at], "must be within 7 days from now"

    ok_min = AgentApproval.new(agent: @agent, action: "deploy", summary: "ok", expires_at: 5.minutes.from_now)
    assert ok_min.valid?, ok_min.errors.full_messages.to_sentence

    ok_max = AgentApproval.new(agent: @agent, action: "deploy", summary: "ok", expires_at: 7.days.from_now)
    assert ok_max.valid?, ok_max.errors.full_messages.to_sentence
  end

  test "enforces unique external_id per agent" do
    AgentApproval.create!(agent: @agent, action: "deploy", summary: "one", external_id: "key-1")
    duplicate = AgentApproval.new(agent: @agent, action: "deploy", summary: "two", external_id: "key-1")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:external_id], "has already been taken"

    other_agent = create_agent_for(users(:kevin))
    other = AgentApproval.new(agent: other_agent, action: "deploy", summary: "other", external_id: "key-1")
    assert other.valid?, other.errors.full_messages.to_sentence
  end

  test "allows multiple rows without an external_id" do
    AgentApproval.create!(agent: @agent, action: "deploy", summary: "one")
    second = AgentApproval.new(agent: @agent, action: "deploy", summary: "two")
    assert second.valid?, second.errors.full_messages.to_sentence
  end

  test "effective_status reads expired once the deadline passes" do
    approval = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok", expires_at: 6.minutes.from_now)
    assert_equal "pending", approval.effective_status

    approval.update_columns(expires_at: 1.minute.ago)
    assert_equal "expired", approval.reload.effective_status
    assert_equal "pending", approval.status
  end

  test "expire_if_due! persists expired only for overdue pending rows" do
    pending = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok")
    assert_not pending.expire_if_due!
    assert_equal "pending", pending.reload.status

    overdue = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok")
    overdue.update_columns(expires_at: 1.minute.ago)
    assert overdue.expire_if_due!
    assert_equal "expired", overdue.reload.status

    decided = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok")
    decided.decide!(decision: "approved", by: users(:david))
    decided.update_columns(expires_at: 1.minute.ago)
    assert_not decided.expire_if_due!
    assert_equal "approved", decided.reload.status
  end

  test "decide! rejects expired and already-decided rows" do
    overdue = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok")
    overdue.update_columns(expires_at: 1.minute.ago)
    error = assert_raises(ActiveRecord::RecordInvalid) { overdue.decide!(decision: "approved", by: users(:david)) }
    assert_match "expired", error.record.errors.full_messages.to_sentence
    assert_equal "expired", overdue.reload.status

    approval = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok")
    approval.decide!(decision: "denied", by: users(:david), note: "nope")
    assert_equal "denied", approval.status
    assert_equal "nope", approval.decision_note

    error = assert_raises(ActiveRecord::RecordInvalid) { approval.decide!(decision: "approved", by: users(:david)) }
    assert_match "already denied", error.record.errors.full_messages.to_sentence
  end

  test "cancel_by_agent! rejects decided and expired rows" do
    approval = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok")
    approval.cancel_by_agent!
    assert_equal "cancelled", approval.reload.status

    error = assert_raises(ActiveRecord::RecordInvalid) { approval.cancel_by_agent! }
    assert_match "already cancelled", error.record.errors.full_messages.to_sentence

    overdue = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok")
    overdue.update_columns(expires_at: 1.minute.ago)
    error = assert_raises(ActiveRecord::RecordInvalid) { overdue.cancel_by_agent! }
    assert_match "expired", error.record.errors.full_messages.to_sentence
  end

  test "rejects decision notes over 200 characters" do
    approval = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok")
    error = assert_raises(ActiveRecord::RecordInvalid) do
      approval.decide!(decision: "denied", by: users(:david), note: "x" * 201)
    end
    assert error.record.errors[:decision_note].any? { |message| message =~ /too long/ }
  end

  test "creates one inbox item per decider" do
    @agent.update!(owner: users(:kevin))

    assert_difference -> { ActivityItem.where(event_type: "agent_approval_request").count }, 3 do
      AgentApproval.create!(agent: @agent, action: "deploy", summary: "ship it")
    end
    # Owner Kevin plus administrators David and Jason.
  end

  test "deciders fall back to administrators when the agent has no owner" do
    @agent.update_columns(owner_id: nil)
    approval = AgentApproval.create!(agent: @agent, action: "deploy", summary: "ok")

    assert_equal [ "David", "Jason" ].sort, approval.deciders.map(&:name).sort
  end

  private
    def create_agent_for(owner)
      bot = User.create_bot!(name: "Approval Test Bot #{SecureRandom.hex(4)}")
      bot.create_agent!(kind: :workspace, owner: owner)
    end

  test "decision webhook is posted after the transaction commits" do
    approval = AgentApproval.create!(agent: agents(:bender_agent), room: rooms(:designers), action: "deploy", summary: "Ship it")
    baseline = ActiveRecord::Base.connection.open_transactions
    depth_at_post = nil

    Agent::Delivery.expects(:post_approval_webhook!).with do |*|
      depth_at_post = ActiveRecord::Base.connection.open_transactions
      true
    end
    approval.decide!(decision: "approved", by: users(:david))

    assert_equal baseline, depth_at_post, "webhook must be posted after the decision transaction commits"
  end

  test "a second decision on an already decided request appends no second event" do
    approval = AgentApproval.create!(agent: agents(:bender_agent), room: rooms(:designers), action: "deploy", summary: "Ship it")
    stale = AgentApproval.find(approval.id)
    approval.decide!(decision: "approved", by: users(:david))
    assert_equal "pending", stale.status, "the second decider still holds the pre-decision row"

    assert_no_difference -> { approval.agent.agent_events.where(event_type: "approval_decided").count } do
      assert_raises(ActiveRecord::RecordInvalid) { stale.decide!(decision: "denied", by: users(:david)) }
    end
    assert_equal "approved", approval.reload.status
  end

  test "cancelling and expiring mark decider inbox items handled" do
    approval = AgentApproval.create!(agent: agents(:bender_agent), room: rooms(:designers), action: "deploy", summary: "Ship it")
    approval.cancel_by_agent!
    assert approval.activity_items.all? { |item| item.handled_at.present? }

    expiring = AgentApproval.create!(agent: agents(:bender_agent), room: rooms(:designers), action: "deploy", summary: "Later", expires_at: 1.hour.from_now)
    travel 2.hours
    assert expiring.expire_if_due!
    assert expiring.activity_items.reload.all? { |item| item.handled_at.present? }
  end
end
