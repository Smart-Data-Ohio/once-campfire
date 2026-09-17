require "test_helper"

class Rooms::BoardTest < ActiveSupport::TestCase
  test "type predicate" do
    assert Rooms::Board.new.board?
    assert_not Rooms::Board.new.open?
    assert_not Rooms::Board.new.closed?
    assert_not Rooms::Board.new.direct?
    assert_not Rooms::Board.new.voice?
    assert_not Rooms::Board.new.stage?
  end

  test "boards scope and channel queries include board rooms" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david) ])

    assert_includes Room.boards, room
    assert_includes Room.without_directs, room
    assert_includes Membership.without_direct_rooms.where(room: room), room.memberships.first
  end

  test "default involvement for new members is mentions" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    assert_equal "mentions", room.default_involvement
    assert room.memberships.all? { |m| m.involved_in_mentions? }
  end

  test "deactivating a user removes their board memberships" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david) ])

    users(:david).deactivate

    assert_not Membership.exists?(room: room, user: users(:david))
  end
end
