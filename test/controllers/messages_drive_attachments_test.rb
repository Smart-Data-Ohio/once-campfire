require "test_helper"

class MessagesDriveAttachmentsTest < ActionDispatch::IntegrationTest
  include GoogleCalendarTestHelper

  FILE_A = "1AbcDefGhIjKlMnOpQrSt"
  FILE_B = "2BcdEfgHiJkLmNoPqRsTu"
  FILE_C = "3CdeFghIjKlMnOpQrStUv"

  setup do
    sign_in :david
    @room = rooms(:watercooler)
  end

  test "create with drive_file_ids stores them in order" do
    post room_messages_url(@room, format: :turbo_stream), params: {
      message: { markdown_source: "see these", drive_file_ids: [ FILE_B, FILE_A ], client_message_id: "drive-create" }
    }

    assert_response :success
    assert_equal [ FILE_B, FILE_A ], Message.last.drive_attachments.map(&:file_id)
  end

  test "create with attachments and no text is valid" do
    assert_difference -> { Message.count }, 1 do
      post room_messages_url(@room, format: :turbo_stream), params: {
        message: { markdown_source: "", drive_file_ids: [ FILE_A ], client_message_id: "drive-textless" }
      }
    end

    assert_response :success
    assert_equal [ FILE_A ], Message.last.drive_attachments.map(&:file_id)
  end

  test "create deduplicates repeated ids and strips blanks" do
    post room_messages_url(@room, format: :turbo_stream), params: {
      message: { markdown_source: "dupes", drive_file_ids: [ FILE_A, "", "  #{FILE_A}  ", FILE_B ], client_message_id: "drive-dedupe" }
    }

    assert_response :success
    assert_equal [ FILE_A, FILE_B ], Message.last.drive_attachments.map(&:file_id)
  end

  test "create with an invalid id answers 422 and creates nothing" do
    assert_no_difference -> { Message.count } do
      assert_no_difference -> { DriveAttachment.count } do
        post room_messages_url(@room, format: :turbo_stream), params: {
          message: { markdown_source: "bad", drive_file_ids: [ FILE_A, "nope" ], client_message_id: "drive-invalid" }
        }
      end
    end

    assert_response :unprocessable_content
  end

  test "create with more than 10 attachments answers 422" do
    assert_no_difference -> { Message.count } do
      post room_messages_url(@room, format: :turbo_stream), params: {
        message: { markdown_source: "too many", drive_file_ids: 11.times.map { |i| "overflow-file-#{i}" }, client_message_id: "drive-overflow" }
      }
    end

    assert_response :unprocessable_content
  end

  test "update with a new set replaces the stored set" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "before", client_message_id: "drive-replace")
    message.drive_attachments.create!([ { file_id: FILE_A }, { file_id: FILE_B } ])

    put room_message_url(@room, message), params: {
      message: { markdown_source: "after", drive_file_ids: [ FILE_C ] }
    }

    assert_redirected_to room_message_url(@room, message)
    assert_equal [ FILE_C ], message.reload.drive_attachments.map(&:file_id)
    assert_equal "after", message.markdown_source
  end

  test "update without the key leaves the set alone" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "before", client_message_id: "drive-untouched")
    message.drive_attachments.create!(file_id: FILE_A)

    put room_message_url(@room, message), params: {
      message: { markdown_source: "after" }
    }

    assert_redirected_to room_message_url(@room, message)
    assert_equal [ FILE_A ], message.reload.drive_attachments.map(&:file_id)
  end

  test "update with only the blank sentinel removes all attachments" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "before", client_message_id: "drive-cleared")
    message.drive_attachments.create!([ { file_id: FILE_A }, { file_id: FILE_B } ])

    assert_difference -> { DriveAttachment.count }, -2 do
      put room_message_url(@room, message), params: {
        message: { markdown_source: "after", drive_file_ids: [ "" ] }
      }
    end

    assert_redirected_to room_message_url(@room, message)
    assert_empty message.reload.drive_attachments
  end

  test "update with an invalid id answers 422 and keeps the stored set" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "before", client_message_id: "drive-bad-update")
    message.drive_attachments.create!(file_id: FILE_A)

    put room_message_url(@room, message), params: {
      message: { markdown_source: "after", drive_file_ids: [ "bogus id" ] }
    }

    assert_response :unprocessable_content
    assert_equal [ FILE_A ], message.reload.drive_attachments.map(&:file_id)
    assert_equal "before", message.markdown_source
  end

  test "a non-creator cannot change attachments" do
    sign_in :jz
    assert_not users(:jz).administrator?

    room = rooms(:designers)
    message = room.messages.where(creator: users(:jason)).first
    message.drive_attachments.create!(file_id: FILE_A)

    assert_no_changes -> { message.reload.drive_attachments.map(&:file_id) } do
      put room_message_url(room, message), params: {
        message: { markdown_source: "hijacked", drive_file_ids: [ FILE_B ] }
      }
    end

    assert_response :forbidden
  end

  test "JSON message shape includes drive_attachments with file_id and url only" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "json", client_message_id: "drive-json")
    message.drive_attachments.create!([ { file_id: FILE_A }, { file_id: FILE_B } ])

    put room_message_url(@room, message, format: :json), params: {
      message: { markdown_source: "json" }
    }

    assert_response :success
    assert_equal [
      { "file_id" => FILE_A, "url" => "https://drive.google.com/open?id=#{FILE_A}" },
      { "file_id" => FILE_B, "url" => "https://drive.google.com/open?id=#{FILE_B}" }
    ], response.parsed_body["drive_attachments"]
  end

  test "JSON message shape carries an empty drive_attachments array without attachments" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "plain", client_message_id: "drive-json-empty")

    put room_message_url(@room, message, format: :json), params: {
      message: { markdown_source: "plain" }
    }

    assert_response :success
    assert_equal [], response.parsed_body["drive_attachments"]
  end

  test "rendered message carries the generic chip with the open link and no file name" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "attached", client_message_id: "drive-render")
    message.drive_attachments.create!(file_id: FILE_A)

    get room_message_url(@room, message)

    assert_response :success
    assert_select "div.drive-attachments[data-controller='drive-link']", count: 1
    assert_select "a.drive-attachment[href='https://drive.google.com/open?id=#{FILE_A}'][target='_blank'][rel='noopener']", count: 1
    assert_select "a.drive-attachment", text: /Google Drive file/
    assert_select "a.drive-attachment", text: /Open in Drive/
  end

  test "viewers with and without Drive consent receive identical attachment markup" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "shared", client_message_id: "drive-cache-safe")
    message.drive_attachments.create!(file_id: FILE_A)

    get room_message_url(@room, message)
    assert_response :success
    without_consent = drive_attachments_html(response.body)

    connect_google!(users(:david), scopes: DRIVE_SCOPES)

    get room_message_url(@room, message)
    assert_response :success
    with_consent = drive_attachments_html(response.body)

    assert_equal without_consent, with_consent
    assert_includes with_consent, "Google Drive file"
  end

  test "edit form lists attachments as removable chips with the blank sentinel" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "edit me", client_message_id: "drive-edit-form")
    message.drive_attachments.create!([ { file_id: FILE_A }, { file_id: FILE_B } ])

    get edit_room_message_url(@room, message)

    assert_response :success
    assert_select ".drive-attachment-chip", count: 2
    assert_select "input[type='hidden'][name='message[drive_file_ids][]'][value='#{FILE_A}']", count: 1
    assert_select "input[type='hidden'][name='message[drive_file_ids][]'][value='#{FILE_B}']", count: 1
    assert_select "input[type='hidden'][name='message[drive_file_ids][]'][value='']", count: 1
    assert_select ".drive-attachment-chip__remove", count: 2
  end

  private
    def drive_attachments_html(body)
      Nokogiri::HTML(body).at_css("div.drive-attachments").to_html
    end
end
