require "test_helper"

class Huddle::ReconcilerTest < ActiveSupport::TestCase
  setup do
    @original_environment = ENV.values_at("LIVEKIT_INTERNAL_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET")
    ENV["LIVEKIT_INTERNAL_URL"] = "http://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
  end

  teardown do
    %w[ LIVEKIT_INTERNAL_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET ].zip(@original_environment).each do |name, value|
      ENV[name] = value
    end
  end

  test "one pass resolves overdue invitations and reconciles cleanup" do
    Huddle::InvitationResolver.expects(:resolve_overdue!).once.with
    HuddleCleanup.expects(:reconcile_now).once.returns(0)

    Huddle::Reconciler.new.reconcile_once
  end

  test "a resolver failure is logged and does not stop cleanup reconciliation" do
    Huddle::InvitationResolver.stubs(:resolve_overdue!).raises(StandardError, "boom")
    Rails.logger.expects(:error).with("Huddle invitation resolution failed: StandardError")
    HuddleCleanup.expects(:reconcile_now).once.returns(0)

    Huddle::Reconciler.new.reconcile_once
  end
end
