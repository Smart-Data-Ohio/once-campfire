require "test_helper"

class ActivityItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    @room = rooms(:designers)
    @source = messages(:first)
    @item = ActivityItem.create!(user: users(:david), source: @source, event_type: "mention")
    sign_in :david
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
end
