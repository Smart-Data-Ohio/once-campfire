require "test_helper"

class ActivityChannelTest < ActionCable::Channel::TestCase
  test "streams only the subscriber's own activity" do
    user = users(:david)
    stub_connection(current_user: user)

    subscribe

    assert subscription.confirmed?
    assert_has_stream ActivityChannel.stream_name_for(user.id)
    assert_not_includes subscription.streams, ActivityChannel.stream_name_for(users(:jason).id)
  end

  test "rejects bots" do
    stub_connection(current_user: users(:bender))
    subscribe
    assert subscription.rejected?
  end

  test "rejects inactive users" do
    user = users(:david)
    stub_connection(current_user: user)
    user.update!(status: :deactivated)
    subscribe
    assert subscription.rejected?
  end
end
