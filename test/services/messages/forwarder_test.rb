require "test_helper"

class Messages::ForwarderTest < ActiveSupport::TestCase
  setup do
    @creator = users(:david)
    @source_room = rooms(:designers)
    @destination = rooms(:watercooler)
    @source = @source_room.root_messages.create_with_attachment!(
      creator: @creator,
      markdown_source: "# Heading\n\n**Formatted** @[Jason]",
      attachment: { io: StringIO.new("source attachment"), filename: "source.txt", content_type: "text/plain" },
      client_message_id: "forward-source"
    )
  end

  test "copies a body and attachment snapshot that survives source edits and deletion" do
    result = Messages::Forwarder.call(source: @source, destinations: [ { room_id: @destination.id } ], note: "Context", creator: @creator).sole
    forwarded = result.message

    assert_predicate forwarded, :forwarded?
    assert_not_predicate forwarded, :markdown?
    assert_includes forwarded.body.body.to_html, "<h1>Heading</h1>"
    assert_equal "source attachment", forwarded.attachment.download
    assert_not_equal @source.attachment.blob_id, forwarded.attachment.blob_id

    @source.update!(markdown_source: "Changed source")
    @source.destroy!

    forwarded.reload
    assert_nil forwarded.forwarded_from_message_id
    assert_includes forwarded.body.body.to_html, "<h1>Heading</h1>"
    assert_equal "source attachment", forwarded.attachment.download
    assert_includes forwarded.plain_text_body, "Context"
  end

  test "copies Drive attachment ids onto room and thread forwards" do
    @source.drive_attachments.create!([ { file_id: "1AbcDefGhIjKlMnOpQrSt" }, { file_id: "2BcdEfgHiJkLmNoPqRsTu" } ])
    thread = ChannelThread.create!(room: @source_room, creator: @creator, name: "Forward attachments")

    results = Messages::Forwarder.call(
      source: @source,
      destinations: [ { room_id: @destination.id }, { room_id: @source_room.id, thread_id: thread.id } ],
      creator: @creator
    )

    assert_equal 2, results.size
    results.each do |result|
      assert_equal %w[ 1AbcDefGhIjKlMnOpQrSt 2BcdEfgHiJkLmNoPqRsTu ], result.message.reload.drive_attachments.map(&:file_id)
    end
  end

  test "a later thread destination failure rolls back prior messages and cloned blobs" do
    thread = ChannelThread.create!(room: @source_room, creator: @creator, name: "Forward destination")
    before_messages = Message.count
    before_memberships = ThreadMembership.count
    before_blobs = ActiveStorage::Blob.count

    ThreadMembership.stubs(:join!).raises(ActiveRecord::RecordInvalid.new(ThreadMembership.new))
    ActiveStorage::Blob.service.expects(:delete).at_least_once

    assert_raises(ActiveRecord::RecordInvalid) do
      Messages::Forwarder.call(
        source: @source,
        destinations: [ { room_id: @destination.id }, { room_id: @source_room.id, thread_id: thread.id } ],
        creator: @creator
      )
    end

    assert_equal before_messages, Message.count
    assert_equal before_memberships, ThreadMembership.count
    assert_equal before_blobs, ActiveStorage::Blob.count
  end

  test "copied body mentions do not notify while a new forward note can" do
    forwarded = Messages::Forwarder.call(
      source: @source,
      destinations: [ { room_id: @destination.id } ],
      note: "@[Jason] please review",
      creator: @creator
    ).sole.message

    assert_equal [ users(:jason) ], forwarded.mentionees.to_a

    forwarded.update!(forward_note: nil)
    assert_empty forwarded.mentionees
  end
end
