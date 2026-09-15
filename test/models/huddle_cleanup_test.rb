require "test_helper"

class HuddleCleanupTest < ActiveSupport::TestCase
  setup do
    @environment_names = %w[ LIVEKIT_INTERNAL_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET ]
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each { |name, value| ENV[name] = value }
  end

  test "an enqueue failure leaves the durable cleanup immediately due" do
    cleanup = build_cleanup
    cleanup.update_columns(enqueued_at: nil, next_attempt_at: nil)
    Huddle::CleanupJob.stubs(:perform_later).raises(RuntimeError)

    assert_not cleanup.enqueue_later
    assert_nil cleanup.reload.enqueued_at
    assert_nil cleanup.next_attempt_at
    assert_nil cleanup.completed_at
  end

  test "a server failure records the attempt and schedules database-backed backoff" do
    cleanup = build_cleanup
    make_due(cleanup)
    Huddle::RoomService.any_instance.stubs(:remove_participant).raises(Huddle::ServerError.new(status: 503))

    assert_not cleanup.perform!

    cleanup.reload
    assert_equal 1, cleanup.attempts
    assert_in_delta Time.current, cleanup.last_attempted_at, 2.seconds
    assert_operator cleanup.next_attempt_at, :>, cleanup.last_attempted_at
    assert_nil cleanup.completed_at
  end

  test "reconciliation performs due work directly without scheduling a delayed job" do
    cleanup = build_cleanup
    make_due(cleanup)
    Huddle::CleanupJob.expects(:perform_later).never
    Huddle::RoomService.any_instance.expects(:remove_participant)
      .with(room_name: cleanup.room_name, identity: cleanup.identity)

    assert_equal 1, HuddleCleanup.reconcile_now

    assert cleanup.reload.completed?
    assert_equal 1, cleanup.attempts
    assert_nil cleanup.next_attempt_at
  end

  test "a queued job consumes its enqueue lease only once" do
    cleanup = build_cleanup
    Huddle::RoomService.any_instance.expects(:remove_participant).once

    assert cleanup.perform_from_queue!
    assert_not cleanup.perform_from_queue!
    assert cleanup.reload.completed?
  end

  test "reconciliation idles without admin configuration" do
    cleanup = build_cleanup
    make_due(cleanup)
    ENV.delete("LIVEKIT_API_SECRET")
    Huddle::RoomService.any_instance.expects(:remove_participant).never

    assert_equal 0, HuddleCleanup.reconcile_now
    assert_equal 0, cleanup.reload.attempts
  end

  private
    def build_cleanup
      HuddleCleanup.create!(
        operation: :remove_participant,
        room_name: "opaque-room",
        identity: "opaque-participant"
      )
    end

    def make_due(cleanup)
      cleanup.update_columns(enqueued_at: nil, next_attempt_at: 1.second.ago)
    end
end
