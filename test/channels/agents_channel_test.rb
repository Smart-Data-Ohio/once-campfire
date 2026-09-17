require "test_helper"

class AgentsChannelTest < ActionCable::Channel::TestCase
  test "a signed-in human may subscribe to the agents stream" do
    stub_connection(current_user: users(:kevin))

    subscribe

    assert subscription.confirmed?
    assert_has_stream AgentsChannel::STREAM_NAME
  end

  test "a bot may not subscribe" do
    stub_connection(current_user: users(:bender))

    subscribe

    assert subscription.rejected?
  end
end
