require "test_helper"

class ActivityItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    @original_api_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    @room = rooms(:designers)
    @source = messages(:first)
    @item = ActivityItem.create!(user: users(:david), source: @source, event_type: "mention")
    sign_in :david
  end

  teardown do
    ENV["LIVEKIT_API_SECRET"] = @original_api_secret
  end

  test "index returns only the signed-in user's accessible activity" do
    other_user_item = ActivityItem.create!(user: users(:jason), source: @source, event_type: "mention")

    get activity_items_url, as: :json

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    payload = response.parsed_body
    assert_equal [ @item.id ], payload.fetch("activity_items").pluck("id")
    assert_equal 1, payload.fetch("unread_count")
    assert_equal room_at_message_path(@room, @source), payload.dig("activity_items", 0, "source", "path")
    assert_not_includes payload.fetch("activity_items").pluck("id"), other_user_item.id
  end

  test "unread count is isolated by user and ignores read and handled items" do
    read_item = ActivityItem.create!(user: users(:david), source: messages(:second), event_type: "reply", read_at: Time.current)
    handled_item = ActivityItem.create!(
      user: users(:david),
      source: messages(:third),
      event_type: "work_update",
      read_at: Time.current,
      handled_at: Time.current
    )
    jason_item = ActivityItem.create!(user: users(:jason), source: messages(:second), event_type: "mention")

    get unread_count_activity_items_url, as: :json

    assert_response :success
    assert_equal({ "unread_count" => 1 }, response.parsed_body)
    assert_not_equal @item.id, jason_item.id
    assert read_item.read_at.present?
    assert handled_item.handled_at.present?

    sign_in :jason
    get unread_count_activity_items_url, as: :json
    assert_response :success
    assert_equal({ "unread_count" => 1 }, response.parsed_body)
  end

  test "index serializes a work event with its thread destination" do
    thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Activity work thread")
    ThreadMembership.join!(thread, users(:jz))
    ThreadMembership.join!(thread, users(:david)).update!(involvement: "everything")
    thread.update_work!(actor: users(:jz), work_status: "planned")
    event = thread.work_thread_events.ordered.first
    work_item = ActivityItem.find_by!(user: users(:david), source: event)

    get activity_items_url, as: :json

    assert_response :success
    payload = response.parsed_body.fetch("activity_items").find { |item| item.fetch("id") == work_item.id }
    assert_equal "WorkThreadEvent", payload.dig("source", "type")
    assert_equal "Status: None → Planned", payload.dig("source", "body")
    assert_equal room_path(@room, thread: thread.id), payload.dig("source", "path")
  end

  test "marking an item handled clears the unread count and records a read timestamp" do
    patch handled_activity_item_url(@item), params: { state: "handled" }, as: :json

    assert_response :success
    assert_predicate @item.reload, :handled?
    assert @item.read_at.present?
    assert_not @item.read?

    get unread_count_activity_items_url, as: :json
    assert_response :success
    assert_equal({ "unread_count" => 0 }, response.parsed_body)

    patch handled_activity_item_url(@item), params: { state: "unhandled" }, as: :json
    assert_response :success
    assert_predicate @item.reload, :read?

    patch read_activity_item_url(@item), params: { state: "unread" }, as: :json
    assert_response :success
    assert_predicate @item.reload, :unread?
  end

  test "revoking the room membership removes an existing item from the inbox" do
    memberships(:david_designers).delete

    get activity_items_url, as: :json

    assert_response :success
    assert_empty response.parsed_body.fetch("activity_items")
    assert_equal 0, response.parsed_body.fetch("unread_count")

    assert_raises(ActiveRecord::RecordNotFound) { post open_activity_item_url(@item) }
    assert_raises(ActiveRecord::RecordNotFound) { patch read_activity_item_url(@item), params: { state: "read" }, as: :json }
    assert_raises(ActiveRecord::RecordNotFound) { patch handled_activity_item_url(@item), params: { state: "handled" }, as: :json }
    assert_predicate @item.reload, :unread?
  end

  test "knowing another recipient's item id does not allow opening or changing it" do
    other_item = ActivityItem.create!(user: users(:jason), source: @source, event_type: "mention")

    assert_raises(ActiveRecord::RecordNotFound) { post open_activity_item_url(other_item) }
    assert_raises(ActiveRecord::RecordNotFound) { patch read_activity_item_url(other_item), params: { state: "read" }, as: :json }
    assert_raises(ActiveRecord::RecordNotFound) { patch handled_activity_item_url(other_item), params: { state: "handled" }, as: :json }
    assert_predicate other_item.reload, :unread?
  end

  test "deleted sources are removed from the inbox and cannot be reopened" do
    item_id = @item.id
    @source.destroy!

    get activity_items_url, as: :json
    assert_response :success
    assert_empty response.parsed_body.fetch("activity_items")
    assert_equal 0, response.parsed_body.fetch("unread_count")

    assert_raises(ActiveRecord::RecordNotFound) { post open_activity_item_url(item_id) }
  end

  test "opening an item marks it read and redirects to the exact message" do
    post open_activity_item_url(@item)

    assert_response :see_other
    assert_redirected_to room_at_message_url(@room, @source)
    assert_predicate @item.reload, :read?
  end

  test "index serializes a huddle invitation with its DM destination" do
    item = start_dm_huddle_for(users(:david))

    get activity_items_url, as: :json

    assert_response :success
    payload = response.parsed_body.fetch("activity_items").find { |entry| entry.fetch("id") == item.id }
    assert_equal "huddle_started", payload.fetch("event_type")
    assert_equal "HuddleGrant", payload.dig("source", "type")
    assert_equal rooms(:david_and_jason).id, payload.dig("source", "room_id")
    assert_equal users(:jason).id, payload.dig("source", "creator_id")
    assert_equal "Jason started a huddle", payload.dig("source", "body")
    assert_equal room_path(rooms(:david_and_jason)), payload.dig("source", "path")
  end

  test "opening a huddle invitation marks it read and redirects to the DM room" do
    item = start_dm_huddle_for(users(:david))

    post open_activity_item_url(item)

    assert_response :see_other
    assert_redirected_to room_url(rooms(:david_and_jason))
    assert_predicate item.reload, :read?
  end

  test "index resolves the current user's overdue invitations but no one else's" do
    # Three minutes back: a handled item inside the two-minute dedup window
    # would keep the fresh start at the end of this test from ringing.
    overdue_item = travel_to 3.minutes.ago do
      start_dm_huddle_for(users(:david))
    end
    # Created directly: issuing through issue! would handle the recipient's
    # own open invitation for the room as a join.
    other_item = travel_to 3.minutes.ago do
      other_grant = HuddleGrant.create!(
        identity: "campfire-participant-#{SecureRandom.hex(32)}",
        room_name: Huddle.room_name(rooms(:david_and_jason).id),
        session: Session.create!(user_id: users(:david).id, user_agent: "huddle test", ip_address: "127.0.0.2"),
        user: users(:david),
        membership: memberships(:david_david_and_jason),
        room: rooms(:david_and_jason)
      )
      ActivityItems::Recorder.record!(recipient: users(:jason), source: other_grant, event_type: "huddle_started")
    end

    get activity_items_url, as: :json

    assert_response :success
    assert_equal "huddle_missed", overdue_item.reload.event_type
    assert_equal "huddle_started", other_item.reload.event_type
    payload = response.parsed_body.fetch("activity_items").find { |entry| entry.fetch("id") == overdue_item.id }
    assert_equal "huddle_missed", payload.fetch("event_type")

    overdue_item.mark_handled!
    fresh_item = start_dm_huddle_for(users(:david))
    get activity_items_url, as: :json
    assert_equal "huddle_started", fresh_item.reload.event_type
  end

  test "started and missed huddles render their copy in the inbox" do
    # The missed item is outside the dedup window so the second ring proceeds;
    # a fresh missed item would suppress it.
    missed_item = travel_to(3.minutes.ago) { start_dm_huddle_for(users(:david)) }
    missed_item.update!(event_type: "huddle_missed")
    started_item = start_dm_huddle_for(users(:david))

    get activity_items_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(started_item)}", text: /Incoming huddle/
    assert_select "##{ActionView::RecordIdentifier.dom_id(started_item)}", text: /Jason started a huddle/
    assert_select "##{ActionView::RecordIdentifier.dom_id(missed_item)}", text: /Missed huddle/
    assert_select "##{ActionView::RecordIdentifier.dom_id(missed_item)}", text: /You missed a huddle from Jason/
  end

  test "event items carry their event in the JSON payload" do
    event = events(:launch_party)
    item = ActivityItem.create!(user: users(:david), source: event, event_type: "event_update")

    get activity_items_url, as: :json

    assert_response :success
    payload = response.parsed_body.fetch("activity_items").find { |entry| entry.fetch("id") == item.id }
    assert_equal "Event", payload.dig("source", "type")
    assert_equal event.id, payload.dig("source", "id")
    assert_equal event.room_id, payload.dig("source", "room_id")
    assert_equal room_event_path(event.room, event), payload.dig("source", "path")
  end

  test "agent approval items carry the approval in the JSON payload" do
    agent = agents(:bender_agent)
    approval = AgentApproval.create!(agent: agent, room: rooms(:designers), action: "deploy", summary: "Ship it")
    item = ActivityItem.find_by!(user: users(:david), source: approval)

    get activity_items_url, as: :json

    assert_response :success
    payload = response.parsed_body.fetch("activity_items").find { |entry| entry.fetch("id") == item.id }
    assert_equal "AgentApproval", payload.dig("source", "type")
    assert_equal approval.id, payload.dig("source", "id")
    assert_equal rooms(:designers).id, payload.dig("source", "room_id")
    assert_equal "pending", payload.dig("source", "status")
    assert_equal "Ship it", payload.dig("source", "body")
    assert_equal agent_approvals_path(agent), payload.dig("source", "path")
  end

  test "index orders items by recency" do
    older = ActivityItem.create!(user: users(:david), source: @room.messages.create!(creator: users(:jz), body: "Older", client_message_id: "order-older"), event_type: "reply")
    older.update_columns(updated_at: 2.days.ago)

    get activity_items_url, as: :json
    assert_equal [ @item.id, older.id ], response.parsed_body.fetch("activity_items").pluck("id")

    older.touch

    get activity_items_url, as: :json
    assert_equal [ older.id, @item.id ], response.parsed_body.fetch("activity_items").pluck("id")
  end

  test "type filters return only their event types as JSON" do
    create_typed_items_for(users(:david))

    ActivityItem::TYPE_FILTER_EVENT_TYPES.each do |type_filter, event_types|
      get activity_items_url(type: type_filter), as: :json

      assert_response :success
      payload = response.parsed_body
      assert_equal type_filter, payload.fetch("type_filter")
      returned_types = payload.fetch("activity_items").pluck("event_type")
      assert_equal event_types.sort, returned_types.uniq.sort
      assert_equal ActivityItem.where(user: users(:david), event_type: event_types).count, returned_types.count
    end

    get activity_items_url, as: :json
    assert_equal "all", response.parsed_body.fetch("type_filter")
    assert_equal ActivityItem.where(user: users(:david)).count, response.parsed_body.fetch("activity_items").count

    get activity_items_url(type: "bogus"), as: :json
    assert_equal "all", response.parsed_body.fetch("type_filter")
    assert_equal ActivityItem.where(user: users(:david)).count, response.parsed_body.fetch("activity_items").count
  end

  test "type filters return only their event types as HTML" do
    create_typed_items_for(users(:david))

    ActivityItem::TYPE_FILTER_EVENT_TYPES.each do |type_filter, event_types|
      get activity_items_url(type: type_filter)

      assert_response :success
      ActivityItem.where(user: users(:david), event_type: event_types).find_each do |item|
        assert_select "##{ActionView::RecordIdentifier.dom_id(item)}", count: 1
      end
      ActivityItem.where(user: users(:david)).where.not(event_type: event_types).find_each do |item|
        assert_select "##{ActionView::RecordIdentifier.dom_id(item)}", count: 0
      end
    end
  end

  test "type filter survives pagination" do
    3.times do |index|
      event = @room.events.create!(organizer: users(:jason), title: "Paged event #{index}", starts_at: 2.days.from_now, time_zone: "UTC")
      ActivityItem.find_by!(user: users(:david), source: event)
    end

    with_page_size(2) do
      get activity_items_url(type: "events")

      assert_response :success
      assert_select "a.activity-inbox__older[href*='type=events']", count: 1

      get activity_items_url(type: "events"), as: :json
      payload = response.parsed_body
      assert_equal 2, payload.fetch("activity_items").count
      assert_not_nil payload.fetch("next_cursor")
      assert_equal "events", payload.fetch("type_filter")

      get activity_items_url(type: "events", before: payload.fetch("next_cursor")), as: :json
      follow_up = response.parsed_body
      assert_equal 1, follow_up.fetch("activity_items").count
      assert_nil follow_up.fetch("next_cursor")
      assert_equal "events", follow_up.fetch("type_filter")
      assert_empty((payload.fetch("activity_items").pluck("id") & follow_up.fetch("activity_items").pluck("id")))
    end
  end

  test "state changes preserve the type filter" do
    patch handled_activity_item_url(@item, state: "handled", status: "read", type: "events")

    assert_redirected_to activity_items_path(status: "read", type: "events")

    patch read_activity_item_url(@item, state: "read", status: "unread", type: "bogus")

    assert_redirected_to activity_items_path(status: "unread", type: "all")
  end

  private
    def create_typed_items_for(user)
      new_message = ->(body) do
        @room.messages.create!(creator: users(:jz), body:, client_message_id: "filter-#{SecureRandom.hex(4)}")
      end

      ActivityItem.create!(user:, source: new_message.call("hello"), event_type: "mention")
      ActivityItem.create!(user:, source: new_message.call("reply"), event_type: "reply")

      thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Filter thread")
      thread_message = thread.post_message!(creator: users(:jz), attributes: { body: "thread", client_message_id: "filter-thread-#{SecureRandom.hex(4)}" })
      ActivityItem.create!(user:, source: thread_message, event_type: "thread_activity")

      work_thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Filter work")
      work_thread.update_work!(actor: users(:jz), work_status: "planned")
      ActivityItem.create!(user:, source: work_thread.work_thread_events.ordered.first, event_type: "work_update")
      work_thread.update_work!(actor: users(:jz), work_owner_id: users(:jason).id)
      ActivityItem.create!(user:, source: work_thread.work_thread_events.ordered.first, event_type: "work_assignment")

      %w[ event_invitation event_update event_cancelled event_reminder ].each_with_index do |event_type, index|
        event = @room.events.create!(organizer: users(:jason), title: "Filter event #{index}", starts_at: 2.days.from_now, time_zone: "UTC")
        ActivityItem.find_by!(user:, source: event).update!(event_type:)
      end

      ActivityItem.create!(user:, source: new_message.call("pr"), event_type: "pr_review_request")

      approval = AgentApproval.create!(agent: agents(:bender_agent), room: @room, action: "deploy", summary: "Ship it")
      ActivityItem.find_by!(user:, source: approval)

      travel_to(3.minutes.ago) { start_dm_huddle_for(user) }.update!(event_type: "huddle_missed")
      start_dm_huddle_for(user)
    end

    def with_page_size(size)
      original = ActivityItemsController::PAGE_SIZE
      ActivityItemsController.send(:remove_const, :PAGE_SIZE)
      ActivityItemsController.const_set(:PAGE_SIZE, size)
      yield
    ensure
      ActivityItemsController.send(:remove_const, :PAGE_SIZE)
      ActivityItemsController.const_set(:PAGE_SIZE, original)
    end

    def start_dm_huddle_for(recipient)
      starter = (rooms(:david_and_jason).user_ids - [ recipient.id ]).first
      session = Session.create!(user_id: starter, user_agent: "huddle test", ip_address: "127.0.0.1")
      membership = Membership.find_by!(room: rooms(:david_and_jason), user_id: starter)
      grant = HuddleGrant.issue!(session:, membership:)
      ActivityItem.find_by!(user: recipient, source: grant)
    end
end
