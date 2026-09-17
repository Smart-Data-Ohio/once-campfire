require "test_helper"

class Rooms::StageTest < ActiveSupport::TestCase
  test "type predicate" do
    assert Rooms::Stage.new.stage?
    assert_not Rooms::Stage.new.voice?
    assert_not Rooms::Stage.new.open?
    assert_not Rooms::Stage.new.closed?
    assert_not Rooms::Stage.new.direct?
  end

  test "stage rooms are listed without directs but outside the voice scope" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david) ])

    assert_includes Room.without_directs, room
    assert_not_includes Room.voices, room
    assert_includes Room.where(type: "Rooms::Stage"), room
    assert_includes Membership.without_direct_rooms.where(room: room), room.memberships.first
  end

  test "default involvement for new members is mentions" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    assert_equal "mentions", room.default_involvement
    assert room.memberships.all? { |m| m.involved_in_mentions? }
  end

  test "the room creator becomes host and every other member becomes a listener" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    assert_equal "host", room.memberships.find_by!(user: users(:david)).stage_role
    assert_equal "listener", room.memberships.find_by!(user: users(:jason)).stage_role
  end

  test "the creator becomes host even when they were not in the member list" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:jason) ])

    assert_equal "host", room.memberships.find_by!(user: users(:david)).stage_role
    assert_equal "listener", room.memberships.find_by!(user: users(:jason)).stage_role
  end

  test "members added later become listeners" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david) ])
    membership = room.memberships.create!(user: users(:jason))

    assert_equal "listener", membership.stage_role
  end

  test "the last host cannot be demoted" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    host = room.memberships.find_by!(user: users(:david))

    error = assert_raises(ActiveRecord::RecordInvalid) { host.change_stage_role!("listener") }
    assert_equal "Stage role can't demote the last host", error.record.errors.full_messages.to_sentence
    assert_equal "host", host.reload.stage_role

    error = assert_raises(ActiveRecord::RecordInvalid) { host.change_stage_role!("speaker") }
    assert_equal "Stage role can't demote the last host", error.record.errors.full_messages.to_sentence
  end

  test "a host can step down once another host exists" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    room.memberships.find_by!(user: users(:jason)).change_stage_role!("host")

    room.memberships.find_by!(user: users(:david)).change_stage_role!("listener")

    assert_equal "listener", room.memberships.find_by!(user: users(:david)).reload.stage_role
  end

  test "non-stage rooms leave the stage columns nil" do
    voice = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    assert_nil voice.memberships.first.stage_role
    assert_nil voice.memberships.first.hand_raised_at
    assert_nil memberships(:david_watercooler).stage_role

    memberships(:david_watercooler).stage_role = "host"
    assert_not memberships(:david_watercooler).valid?
  end

  test "only listeners can raise a hand, and any promotion clears it" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    listener = room.memberships.find_by!(user: users(:jason))

    listener.raise_hand!
    assert_predicate listener.reload, :hand_raised?

    listener.change_stage_role!("speaker")
    assert_equal "speaker", listener.reload.stage_role
    assert_not_predicate listener, :hand_raised?

    assert_raises(ActiveRecord::RecordInvalid) { listener.raise_hand! }
    assert_raises(ActiveRecord::RecordInvalid) { room.memberships.find_by!(user: users(:david)).raise_hand! }
  end

  test "lowering a hand that was never raised succeeds" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    listener = room.memberships.find_by!(user: users(:jason))

    listener.lower_hand!
    assert_not_predicate listener.reload, :hand_raised?
  end

  test "stage members can reach the room's messages like any channel" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david) ])
    message = room.messages.create!(creator: users(:david), body: "Hello from stage")

    assert_includes users(:david).reachable_messages, message
    assert_not_includes users(:jason).reachable_messages, message
  end

  test "deactivating a user removes their stage memberships" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david) ])

    users(:david).deactivate

    assert_not Membership.exists?(room: room, user: users(:david))
  end
end
