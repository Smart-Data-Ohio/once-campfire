require "test_helper"

class RoomTest < ActiveSupport::TestCase
  test "grant membership to user" do
    rooms(:watercooler).memberships.grant_to(users(:kevin))
    assert rooms(:watercooler).users.include?(users(:kevin))
  end

  test "revoke membership from user" do
    rooms(:watercooler).memberships.revoke_from(users(:david))
    assert_not rooms(:watercooler).users.include?(users(:david))
  end

  test "revise memberships" do
    rooms(:watercooler).memberships.revise(granted: users(:kevin), revoked: users(:david))
    assert rooms(:watercooler).users.include?(users(:kevin))
    assert_not rooms(:watercooler).users.include?(users(:david))
  end

  test "create for users by giving them immediate membership" do
    room = Rooms::Closed.create_for({ name: "Hello!", creator: users(:david) }, users: [ users(:kevin), users(:david) ])
    assert room.users.include?(users(:kevin))
    assert room.users.include?(users(:david))
  end

  test "type" do
    assert Rooms::Open.new.open?
    assert_not Rooms::Open.new.direct?
    assert Rooms::Direct.new.direct?
    assert Rooms::Closed.new.closed?
  end

  test "default involvement for new users" do
    room = Rooms::Closed.create_for({ name: "Hello!", creator: users(:david) }, users: [ users(:kevin), users(:david) ])
    assert room.memberships.all? { |m| m.involved_in_mentions? }
  end

  test "icon_name accepts brand, workspace, and emoji names and normalizes colons" do
    create_workspace_icon(name: "acme")

    {
      "openai" => "openai", ":openai:" => "openai", "  :OpenAI: " => "openai",
      "gpt" => "gpt", "acme" => "acme", ":acme:" => "acme",
      "thumbsup" => "thumbsup", ":fire:" => "fire"
    }.each do |given, expected|
      room = rooms(:pets)
      room.icon_name = given

      assert room.valid?, "#{given.inspect} should be valid: #{room.errors.full_messages.to_sentence}"
      assert_equal expected, room.icon_name
    end
  end

  test "icon_name allows nil and blank" do
    room = rooms(:pets)

    room.icon_name = nil
    assert room.valid?

    room.icon_name = ""
    assert room.valid?
    assert_nil room.icon_name
  end

  test "icon_name rejects unknown names" do
    room = rooms(:pets)
    room.icon_name = "nope_not_real"

    assert_not room.valid?
    assert_equal [ "is not a known icon" ], room.errors[:icon_name]
  end

  test "unrelated saves succeed after the workspace icon is deleted" do
    create_workspace_icon(name: "acme")
    room = rooms(:pets)
    room.update!(icon_name: "acme")
    WorkspaceIcon.find_by!(name: "acme").destroy

    assert room.update(name: "Renamed Room")
    assert_equal "acme", room.reload.icon_name
  end
end
