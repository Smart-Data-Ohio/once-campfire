require "test_helper"

class Huddle::RoomServiceTest < ActiveSupport::TestCase
  setup do
    @environment_names = %w[ LIVEKIT_INTERNAL_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET ]
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_INTERNAL_URL"] = "wss://livekit-internal.example.test"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each do |name, value|
      ENV[name] = value
    end
  end

  test "removes only the requested participant using a room-scoped admin token" do
    stub_request(:post, "https://livekit-internal.example.test/twirp/livekit.RoomService/RemoveParticipant")
      .to_return(status: 200, body: "{}")

    Huddle::RoomService.new.remove_participant(room_name: "opaque-room", identity: "opaque-participant")

    assert_requested :post, "https://livekit-internal.example.test/twirp/livekit.RoomService/RemoveParticipant" do |actual|
      claims = decode_authorization(actual)
      body = JSON.parse(actual.body)

      body == { "room" => "opaque-room", "identity" => "opaque-participant" } &&
        claims.fetch("iss") == "test-api-key" &&
        claims.fetch("video") == { "roomAdmin" => true, "room" => "opaque-room" }
    end
  end

  test "deletes only the requested room using a room-create token" do
    stub_request(:post, "https://livekit-internal.example.test/twirp/livekit.RoomService/DeleteRoom")
      .to_return(status: 200, body: "{}")

    Huddle::RoomService.new.delete_room(room_name: "opaque-room")

    assert_requested :post, "https://livekit-internal.example.test/twirp/livekit.RoomService/DeleteRoom" do |actual|
      JSON.parse(actual.body) == { "room" => "opaque-room" } &&
        decode_authorization(actual).fetch("video") == { "roomCreate" => true }
    end
  end

  test "treats an already-absent participant as removed" do
    stub_request(:post, "https://livekit-internal.example.test/twirp/livekit.RoomService/RemoveParticipant")
      .to_return(status: 404, body: '{"code":"not_found"}')

    assert_nothing_raised do
      Huddle::RoomService.new.remove_participant(room_name: "opaque-room", identity: "opaque-participant")
    end
  end

  test "raises a safe error without following redirects or retaining a response body" do
    request = stub_request(:post, "https://livekit-internal.example.test/twirp/livekit.RoomService/RemoveParticipant")
      .to_return(status: 302, headers: { "Location" => "https://other.example.test" }, body: "sensitive upstream body")

    error = assert_raises(Huddle::ServerError) do
      Huddle::RoomService.new.remove_participant(room_name: "opaque-room", identity: "opaque-participant")
    end

    assert_equal 302, error.status
    assert_nil error.code
    assert_not_includes error.message, "sensitive upstream body"
    assert_requested request, times: 1
    assert_not_requested :post, "https://other.example.test"
  end

  private
    def decode_authorization(request)
      token = request.headers.fetch("Authorization").delete_prefix("Bearer ")
      claims, = JWT.decode(token, "test-api-secret", true, algorithm: "HS256")
      claims
    end
end
