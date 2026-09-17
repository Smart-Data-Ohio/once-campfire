require "test_helper"

class DriveAttachmentTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:watercooler)
    @creator = users(:david)
  end

  test "a message with attachments and no text is valid" do
    message = @room.messages.new(creator: @creator, markdown_source: "", client_message_id: "drive-only")
    message.drive_attachments.build(file_id: "1AbcDefGhIjKlMnOpQrSt")

    assert message.valid?, message.errors.full_messages.to_sentence
    assert message.save
    assert_equal %w[ 1AbcDefGhIjKlMnOpQrSt ], message.reload.drive_attachments.map(&:file_id)
  end

  test "a textless message without attachments is still invalid" do
    message = @room.messages.new(creator: @creator, markdown_source: "", client_message_id: "blank-still-invalid")

    assert_not message.valid?
    assert_includes message.errors[:markdown_source], "can't be blank"
  end

  test "an invalid file id is rejected" do
    message = @room.messages.new(creator: @creator, markdown_source: "see attached", client_message_id: "drive-bad-id")

    [ "short", "not a file id!!", "https://drive.google.com/open?id=1AbcDefGhIjKlMnOpQrSt", "" ].each do |bad_id|
      attachment = message.drive_attachments.build(file_id: bad_id)

      assert_not attachment.valid?, "expected #{bad_id.inspect} to be invalid"
      assert_includes attachment.errors[:file_id], "is invalid"
      message.drive_attachments.delete(attachment)
    end
  end

  test "duplicate file ids on one message collapse to a single row" do
    message = @room.messages.create!(creator: @creator, markdown_source: "dupes", client_message_id: "drive-dupes")
    message.drive_attachments.create!(file_id: "1AbcDefGhIjKlMnOpQrSt")

    duplicate = message.drive_attachments.build(file_id: "1AbcDefGhIjKlMnOpQrSt")

    assert_not duplicate.valid?
    assert_not_empty duplicate.errors[:file_id]
  end

  test "the same file id may attach to different messages" do
    first = @room.messages.create!(creator: @creator, markdown_source: "first", client_message_id: "drive-shared-1")
    second = @room.messages.create!(creator: @creator, markdown_source: "second", client_message_id: "drive-shared-2")

    first.drive_attachments.create!(file_id: "1AbcDefGhIjKlMnOpQrSt")
    second.drive_attachments.create!(file_id: "1AbcDefGhIjKlMnOpQrSt")

    assert_equal 1, first.drive_attachments.count
    assert_equal 1, second.drive_attachments.count
  end

  test "the 11th attachment is rejected" do
    message = @room.messages.new(creator: @creator, markdown_source: "many", client_message_id: "drive-eleven")
    10.times { |i| message.drive_attachments.build(file_id: "ten-files-#{i}1") }

    assert message.valid?, message.errors.full_messages.to_sentence

    message.drive_attachments.build(file_id: "eleventh-file")

    assert_not message.valid?
    assert_equal [ "are limited to 10 per message" ], message.errors[:drive_attachments]
  end

  test "destroying the message destroys its attachments" do
    message = @room.messages.create!(creator: @creator, markdown_source: "doomed", client_message_id: "drive-doomed")
    message.drive_attachments.create!(file_id: "1AbcDefGhIjKlMnOpQrSt")

    assert_difference -> { DriveAttachment.count }, -1 do
      message.destroy!
    end
  end

  test "url is the open link for the file id" do
    attachment = DriveAttachment.new(file_id: "1AbcDefGhIjKlMnOpQrSt")

    assert_equal "https://drive.google.com/open?id=1AbcDefGhIjKlMnOpQrSt", attachment.url
  end
end
