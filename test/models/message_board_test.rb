require "test_helper"

class MessageBoardTest < ActiveSupport::TestCase
  test "root messages are rejected in a board but thread replies are allowed" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david) ])
    post = ChannelThread.create!(room: room, creator: users(:david), name: "Post", work_status: "planned")

    root = room.messages.build(creator: users(:david), body: "Hello board")
    assert_not root.valid?
    assert_includes root.errors[:thread], "must be present in a board"

    reply = post.post_message!(creator: users(:david), attributes: { markdown_source: "A reply" })
    assert_predicate reply, :persisted?

    channel_root = rooms(:designers).messages.build(creator: users(:david), body: "Hello channel")
    assert channel_root.valid?
  end
end
