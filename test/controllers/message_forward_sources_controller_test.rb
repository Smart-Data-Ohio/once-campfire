require "test_helper"

class MessageForwardSourcesControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "smartfire.test"
    @private_room = Rooms::Closed.create_for({ name: "Private source", creator: users(:david) }, users: [ users(:david) ])
    @source = @private_room.root_messages.create!(creator: users(:david), markdown_source: "Private message", client_message_id: "private-forward-source")
    @forwarded = Messages::Forwarder.call(
      source: @source,
      destinations: [ { room_id: rooms(:designers).id } ],
      creator: users(:david)
    ).sole.message
  end

  test "source endpoint is no-store and keeps inaccessible source identity out of the response" do
    sign_in :jz

    get forward_source_room_message_url(rooms(:designers), @forwarded, format: :json)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({ "source" => nil }, response.parsed_body)
    assert_no_match @source.id.to_s, response.body
    assert_no_match users(:david).name, response.body
  end

  test "source endpoint returns only the canonical URL to a viewer who still has access" do
    sign_in :david

    get forward_source_room_message_url(rooms(:designers), @forwarded, format: :json)

    assert_response :success
    assert_equal room_at_message_url(@private_room, @source), response.parsed_body.dig("source", "url")
    assert_equal [ "source" ], response.parsed_body.keys
  end
end
