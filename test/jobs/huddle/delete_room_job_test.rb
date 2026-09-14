require "test_helper"

class Huddle::DeleteRoomJobTest < ActiveJob::TestCase
  setup do
    @original_livekit_environment = ENV.values_at("LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET")
    ENV["LIVEKIT_URL"] = "wss://livekit.example.test"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
  end

  teardown do
    %w[ LIVEKIT_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET ].zip(@original_livekit_environment).each do |name, value|
      ENV[name] = value
    end
  end

  test "deletes the specified room" do
    Huddle::RoomService.any_instance.expects(:delete_room).with(room_name: "opaque-room")

    Huddle::DeleteRoomJob.perform_now("opaque-room")
  end

  test "does nothing when huddles are not configured" do
    ENV.delete("LIVEKIT_API_SECRET")
    Huddle::RoomService.expects(:new).never

    Huddle::DeleteRoomJob.perform_now("opaque-room")
  end

  test "retries LiveKit failures" do
    Huddle::RoomService.any_instance.stubs(:delete_room).raises(Huddle::ServerError.new(status: 503))

    assert_enqueued_with(job: Huddle::DeleteRoomJob, args: [ "opaque-room" ]) do
      Huddle::DeleteRoomJob.perform_now("opaque-room")
    end
  end
end
