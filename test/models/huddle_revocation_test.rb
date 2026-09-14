require "test_helper"

class HuddleRevocationTest < ActiveSupport::TestCase
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

  test "membership revocation removes only that user's sessions from that room" do
    membership = memberships(:david_watercooler)
    david_session = sessions(:david_safari)
    jason_session = users(:jason).sessions.create!(user_agent: "Test")

    membership.destroy!

    assert_equal [ [ Huddle.room_name(membership.room_id), Huddle.identity(david_session.id) ] ], participant_job_args
    assert_not_includes participant_job_args.flatten, Huddle.identity(jason_session.id)
  end

  test "session removal revokes only that session from every accessible room" do
    target_session = sessions(:david_safari)
    other_session = users(:david).sessions.create!(user_agent: "Other device")
    expected_rooms = users(:david).room_ids.map { |room_id| Huddle.room_name(room_id) }

    target_session.destroy!

    assert_equal expected_rooms.sort, participant_job_args.map(&:first).sort
    assert participant_job_args.all? { |_, identity| identity == Huddle.identity(target_session.id) }
    assert_not_includes participant_job_args.flatten, Huddle.identity(other_session.id)
  end

  test "banning a user captures all rooms and sessions before bulk deletion" do
    user = users(:kevin)
    sessions = 2.times.map { user.sessions.create!(user_agent: "Test") }
    expected = Huddle.participant_revocations(room_ids: user.room_ids, session_ids: sessions.map(&:id))

    user.ban

    assert_equal expected.sort, participant_job_args.sort
  end

  test "deactivating a user captures direct and shared rooms before bulk deletion" do
    user = users(:david)
    expected = Huddle.participant_revocations(room_ids: user.room_ids, session_ids: user.session_ids)

    user.deactivate

    assert_equal expected.sort, participant_job_args.sort
    assert expected.any? { |room_name, _| room_name == Huddle.room_name(rooms(:david_and_jason).id) }
  end

  test "destroying a room deletes only its LiveKit room" do
    room = rooms(:watercooler)
    expected_room_name = Huddle.room_name(room.id)

    room.destroy!

    assert_equal [ [ expected_room_name ] ], room_job_args
    assert_empty participant_job_args
  end

  test "lifecycle changes enqueue no cleanup when huddles are not configured" do
    ENV.delete("LIVEKIT_API_SECRET")

    memberships(:david_watercooler).destroy!
    sessions(:david_safari).destroy!
    rooms(:designers).destroy!

    assert_empty participant_job_args
    assert_empty room_job_args
  end

  private
    def participant_job_args
      enqueued_jobs.filter_map { |job| job[:args] if job[:job] == Huddle::RevokeParticipantJob }
    end

    def room_job_args
      enqueued_jobs.filter_map { |job| job[:args] if job[:job] == Huddle::DeleteRoomJob }
    end
end
