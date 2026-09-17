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

  private
    def start_dm_huddle_for(recipient)
      starter = (rooms(:david_and_jason).user_ids - [ recipient.id ]).first
      session = Session.create!(user_id: starter, user_agent: "huddle test", ip_address: "127.0.0.1")
      membership = Membership.find_by!(room: rooms(:david_and_jason), user_id: starter)
      grant = HuddleGrant.issue!(session:, membership:)
      ActivityItem.find_by!(user: recipient, source: grant)
    end
end
