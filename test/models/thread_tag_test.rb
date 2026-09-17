require "test_helper"

class ThreadTagTest < ActiveSupport::TestCase
  setup do
    @room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david) ])
    @thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Tagged post", work_status: "planned")
  end

  test "name is required, lowercase, and limited in length" do
    tag = @thread.tags.build(name: "")

    assert_not tag.valid?
    assert_includes tag.errors[:name], "can't be blank"

    tag.name = "Needs Work!"
    assert_not tag.valid?

    tag.name = "a" * 31
    assert_not tag.valid?

    tag.name = "api-v2"
    assert tag.valid?
  end

  test "names are unique per post but reusable across posts" do
    @thread.tags.create!(name: "bug")
    other = ChannelThread.create!(room: @room, creator: users(:david), name: "Other post", work_status: "planned")

    assert_not @thread.tags.build(name: "bug").valid?
    assert other.tags.build(name: "bug").valid?
  end
end
