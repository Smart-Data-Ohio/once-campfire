require "test_helper"

class Huddle::RevokeParticipantJobTest < ActiveJob::TestCase
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

  test "removes the specified participant" do
    Huddle::RoomService.any_instance.expects(:remove_participant)
      .with(room_name: "opaque-room", identity: "opaque-participant")

    Huddle::RevokeParticipantJob.perform_now("opaque-room", "opaque-participant")
  end

  test "does nothing when huddles are not configured" do
    ENV.delete("LIVEKIT_API_SECRET")
    Huddle::RoomService.expects(:new).never

    Huddle::RevokeParticipantJob.perform_now("opaque-room", "opaque-participant")
  end

  test "retries LiveKit failures" do
    Huddle::RoomService.any_instance.stubs(:remove_participant).raises(Huddle::ServerError.new(status: 503))

    assert_enqueued_with(job: Huddle::RevokeParticipantJob, args: [ "opaque-room", "opaque-participant" ]) do
      Huddle::RevokeParticipantJob.perform_now("opaque-room", "opaque-participant")
    end
  end
end
