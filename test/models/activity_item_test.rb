require "test_helper"

class ActivityItemTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @user = users(:david)
    @source = messages(:first)
    @item = ActivityItem.create!(user: @user, source: @source, event_type: "mention")
  end

  test "state transitions preserve the distinction between unread, read, and handled" do
    assert_predicate @item, :unread?
    assert_equal "unread", @item.state

    @item.mark_read!
    assert_predicate @item, :read?
    assert_equal "read", @item.state

    @item.mark_handled!
    assert_predicate @item, :handled?
    assert @item.read_at.present?
    assert_not @item.read?
    assert_equal "handled", @item.state

    @item.mark_unhandled!
    assert_predicate @item, :read?
    assert_equal "read", @item.state

    @item.mark_unread!
    assert_predicate @item, :unread?
    assert_equal "unread", @item.state
  end

  test "state changes notify the recipient's activity stream" do
    stream = ActivityChannel.stream_name_for(@user.id)

    assert_broadcasts stream, 1 do
      @item.mark_read!
    end

    assert_broadcasts stream, 1 do
      @item.mark_handled!
    end

    assert_broadcasts stream, 1 do
      @item.mark_unhandled!
    end

    assert_broadcasts stream, 1 do
      @item.mark_unread!
    end
  end

  test "marking a handled item unread clears both state timestamps" do
    @item.mark_handled!
    @item.mark_unread!

    assert_predicate @item.reload, :unread?
    assert_nil @item.read_at
    assert_nil @item.handled_at
  end

  test "accessible items follow current membership and active human access" do
    assert_includes ActivityItem.accessible_to(@user), @item

    memberships(:david_designers).delete
    assert_not ActivityItem.accessible_to(@user).exists?(@item.id)
  end

  test "inactive users and bots cannot access activity items" do
    assert_empty ActivityItem.accessible_to(users(:bender))

    @user.update!(status: :deactivated)
    assert_empty ActivityItem.accessible_to(@user)
  end
end
