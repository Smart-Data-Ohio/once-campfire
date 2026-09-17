require "test_helper"

class Rooms::VoiceTest < ActiveSupport::TestCase
  test "type predicate" do
    assert Rooms::Voice.new.voice?
    assert_not Rooms::Voice.new.open?
    assert_not Rooms::Voice.new.closed?
    assert_not Rooms::Voice.new.direct?
  end

  test "voices scope and channel queries include voice rooms" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    assert_includes Room.voices, room
    assert_includes Room.without_directs, room
    assert_includes Membership.without_direct_rooms.where(room: room), room.memberships.first
  end

  test "default involvement for new members is mentions" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    assert_equal "mentions", room.default_involvement
    assert room.memberships.all? { |m| m.involved_in_mentions? }
  end

  test "voice members can reach the room's messages like any channel" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])
    message = room.messages.create!(creator: users(:david), body: "Hello from voice")

    assert_includes users(:david).reachable_messages, message
    assert_not_includes users(:jason).reachable_messages, message
  end

  test "deactivating a user removes their voice memberships" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    users(:david).deactivate

    assert_not Membership.exists?(room: room, user: users(:david))
  end
end
