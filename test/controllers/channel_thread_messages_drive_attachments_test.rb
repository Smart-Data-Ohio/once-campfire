require "test_helper"

class ChannelThreadMessagesDriveAttachmentsTest < ActionDispatch::IntegrationTest
  FILE_A = "1AbcDefGhIjKlMnOpQrSt"
  FILE_B = "2BcdEfgHiJkLmNoPqRsTu"
  FILE_C = "3CdeFghIjKlMnOpQrStUv"

  setup do
    host! "once.campfire.test"
    sign_in :jz
    @room = rooms(:designers)
    @thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Thread attachments")
    ThreadMembership.join!(@thread, users(:jz))
  end

  test "create with drive_file_ids stores them and reports them in JSON" do
    post room_thread_messages_url(@room, @thread, format: :json), params: {
      message: { markdown_source: "see these", drive_file_ids: [ FILE_B, FILE_A ], client_message_id: "thread-drive-create" }
    }

    assert_response :created
    assert_equal [ FILE_B, FILE_A ], @thread.messages.order(:id).last.drive_attachments.map(&:file_id)
    assert_equal [
      { "file_id" => FILE_B, "url" => "https://drive.google.com/open?id=#{FILE_B}" },
      { "file_id" => FILE_A, "url" => "https://drive.google.com/open?id=#{FILE_A}" }
    ], response.parsed_body["drive_attachments"]
  end

  test "create with attachments and no text is valid" do
    assert_difference -> { @thread.messages.count }, 1 do
      post room_thread_messages_url(@room, @thread, format: :json), params: {
        message: { markdown_source: "", drive_file_ids: [ FILE_A ], client_message_id: "thread-drive-textless" }
      }
    end

    assert_response :created
    assert_equal [ FILE_A ], @thread.messages.order(:id).last.drive_attachments.map(&:file_id)
  end

  test "create with an invalid id answers 422 and creates nothing" do
    assert_no_difference -> { Message.count } do
      assert_no_difference -> { DriveAttachment.count } do
        post room_thread_messages_url(@room, @thread, format: :json), params: {
          message: { markdown_source: "bad", drive_file_ids: [ FILE_A, "nope" ], client_message_id: "thread-drive-invalid" }
        }
      end
    end

    assert_response :unprocessable_content
  end

  test "create with a scalar drive_file_ids answers 422 and creates nothing" do
    assert_no_difference -> { Message.count } do
      post room_thread_messages_url(@room, @thread, format: :json), params: {
        message: { markdown_source: "scalar", drive_file_ids: FILE_A, client_message_id: "thread-drive-scalar-create" }
      }
    end

    assert_response :unprocessable_content
  end

  test "create with more than 10 attachments answers 422" do
    assert_no_difference -> { Message.count } do
      post room_thread_messages_url(@room, @thread, format: :json), params: {
        message: { markdown_source: "too many", drive_file_ids: 11.times.map { |i| "overflow-file-#{i}" }, client_message_id: "thread-drive-overflow" }
      }
    end

    assert_response :unprocessable_content
  end

  test "update with a new set replaces the stored set" do
    message = post_thread_message(markdown_source: "before", client_message_id: "thread-drive-replace")
    message.drive_attachments.create!([ { file_id: FILE_A }, { file_id: FILE_B } ])

    patch room_thread_message_url(@room, @thread, message, format: :json), params: {
      message: { markdown_source: "after", drive_file_ids: [ FILE_C ] }
    }

    assert_response :success
    assert_equal [ FILE_C ], message.reload.drive_attachments.map(&:file_id)
    assert_equal "after", message.markdown_source
  end

  test "update without the key leaves the set alone" do
    message = post_thread_message(markdown_source: "before", client_message_id: "thread-drive-untouched")
    message.drive_attachments.create!(file_id: FILE_A)

    patch room_thread_message_url(@room, @thread, message, format: :json), params: {
      message: { markdown_source: "after" }
    }

    assert_response :success
    assert_equal [ FILE_A ], message.reload.drive_attachments.map(&:file_id)
  end

  test "update with only the blank sentinel removes all attachments" do
    message = post_thread_message(markdown_source: "before", client_message_id: "thread-drive-cleared")
    message.drive_attachments.create!([ { file_id: FILE_A }, { file_id: FILE_B } ])

    assert_difference -> { DriveAttachment.count }, -2 do
      patch room_thread_message_url(@room, @thread, message, format: :json), params: {
        message: { markdown_source: "after", drive_file_ids: [ "" ] }
      }
    end

    assert_response :success
    assert_empty message.reload.drive_attachments
  end

  test "update with an invalid id answers 422 and keeps the stored set" do
    message = post_thread_message(markdown_source: "before", client_message_id: "thread-drive-bad-update")
    message.drive_attachments.create!(file_id: FILE_A)

    patch room_thread_message_url(@room, @thread, message, format: :json), params: {
      message: { markdown_source: "after", drive_file_ids: [ "bogus id" ] }
    }

    assert_response :unprocessable_content
    assert_equal [ FILE_A ], message.reload.drive_attachments.map(&:file_id)
    assert_equal "before", message.markdown_source
  end

  test "update with a scalar drive_file_ids answers 422 and keeps the stored set" do
    message = post_thread_message(markdown_source: "before", client_message_id: "thread-drive-scalar")
    message.drive_attachments.create!(file_id: FILE_A)

    patch room_thread_message_url(@room, @thread, message, format: :json), params: {
      message: { markdown_source: "after", drive_file_ids: FILE_B }
    }

    assert_response :unprocessable_content
    assert_equal [ FILE_A ], message.reload.drive_attachments.map(&:file_id)
  end

  test "a non-creator cannot change thread attachments" do
    sign_in :kevin
    assert_not users(:kevin).administrator?

    message = post_thread_message(markdown_source: "mine", client_message_id: "thread-drive-guarded")
    message.drive_attachments.create!(file_id: FILE_A)

    assert_no_changes -> { message.reload.drive_attachments.map(&:file_id) } do
      patch room_thread_message_url(@room, @thread, message, format: :json), params: {
        message: { markdown_source: "hijacked", drive_file_ids: [ FILE_B ] }
      }
    end

    assert_response :forbidden
  end

  test "update with a submitted set broadcasts the attachments block over the thread stream" do
    message = post_thread_message(markdown_source: "before", client_message_id: "thread-drive-broadcast")
    message.drive_attachments.create!(file_id: FILE_A)

    broadcasts = capture_broadcasts(thread_messages_stream_name(@thread)) do
      patch room_thread_message_url(@room, @thread, message, format: :json), params: {
        message: { markdown_source: "after", drive_file_ids: [ "" ] }
      }
    end

    block = broadcasts.map(&:to_s).find { |html| html.include?("#{dom_id(message, :drive_attachments)}") }
    assert block, "expected a replace for the attachments block"
    assert_no_match FILE_A, block
  end

  test "update without the key does not broadcast the attachments block" do
    message = post_thread_message(markdown_source: "before", client_message_id: "thread-drive-nobroadcast")
    message.drive_attachments.create!(file_id: FILE_A)

    broadcasts = capture_broadcasts(thread_messages_stream_name(@thread)) do
      patch room_thread_message_url(@room, @thread, message, format: :json), params: {
        message: { markdown_source: "after" }
      }
    end

    assert_nil broadcasts.map(&:to_s).find { |html| html.include?("#{dom_id(message, :drive_attachments)}") }
  end

  private
    def post_thread_message(**attributes)
      @thread.post_message!(creator: users(:jz), attributes:)
    end

    def thread_messages_stream_name(thread)
      Turbo::StreamsChannel.signed_stream_name([ thread, :messages ]).then { |signed| Turbo::StreamsChannel.verified_stream_name(signed) }
    end
end
