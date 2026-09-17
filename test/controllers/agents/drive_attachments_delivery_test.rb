require "test_helper"

class Agents::DriveAttachmentsDeliveryTest < ActionDispatch::IntegrationTest
  FILE_A = "1AbcDefGhIjKlMnOpQrSt"
  FILE_B = "2BcdEfgHiJkLmNoPqRsTu"

  setup do
    @room = rooms(:watercooler)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
  end

  test "polling carries drive_attachments with file_id and url only" do
    message = @room.messages.create!(
      creator: users(:david), markdown_source: "Hey @[Bender Bot], see these",
      client_message_id: "drive-poll"
    )
    message.drive_attachments.create!([ { file_id: FILE_A }, { file_id: FILE_B } ])

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.find { |entry| entry.dig("message", "id") == message.id }
    assert row, "expected a row for message #{message.id} in #{response.parsed_body.inspect}"
    assert_equal [
      { "file_id" => FILE_A, "url" => "https://drive.google.com/open?id=#{FILE_A}" },
      { "file_id" => FILE_B, "url" => "https://drive.google.com/open?id=#{FILE_B}" }
    ], row.dig("message", "drive_attachments")
  end

  test "polling carries an empty drive_attachments array without attachments" do
    message = @room.messages.create!(
      creator: users(:david), markdown_source: "Hey @[Bender Bot]",
      client_message_id: "drive-poll-empty"
    )

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.find { |entry| entry.dig("message", "id") == message.id }
    assert_equal [], row.dig("message", "drive_attachments")
  end

  test "agent webhook posts drive_attachments without names" do
    message = @room.messages.create!(
      creator: users(:david), markdown_source: "Hey @[Bender Bot], see these",
      client_message_id: "drive-webhook"
    )
    message.drive_attachments.create!(file_id: FILE_A)

    perform_enqueued_jobs only: Agent::DeliveryJob

    assert_requested :post, webhooks(:bender).url, body: hash_including(
      "agent" => hash_including("id" => @agent.id),
      "message" => hash_including(
        "drive_attachments" => [ { "file_id" => FILE_A, "url" => "https://drive.google.com/open?id=#{FILE_A}" } ]
      )
    ), times: 1
  end

  private
    def bearer_headers
      { "Authorization" => "Bearer #{@secret}" }
    end
end
