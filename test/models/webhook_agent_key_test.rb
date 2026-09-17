require "test_helper"

class WebhookAgentKeyTest < ActiveSupport::TestCase
  test "deliver without agent context sends the legacy payload unchanged" do
    message = messages(:first)
    bot_messages_path = Rails.application.routes.url_helpers.room_bot_messages_path(message.room, users(:bender).bot_key)

    WebMock.stub_request(:post, webhooks(:bender).url)
      .with(body: hash_excluding("agent"))
      .to_return(status: 200)

    webhooks(:bender).deliver(message)

    assert_requested :post, webhooks(:bender).url, body: hash_including(
      "room" => hash_including("path" => bot_messages_path)
    ), times: 1
  end

  test "deliver with agent context adds the agent key alongside existing keys" do
    message = messages(:first)
    agent = agents(:bender_agent)

    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    webhooks(:bender).deliver(message, agent: agent, delivery_id: 123)

    assert_requested :post, webhooks(:bender).url, body: hash_including(
      "user" => hash_including("id" => message.creator.id),
      "room" => hash_including("id" => message.room.id),
      "message" => hash_including("id" => message.id),
      "agent" => {
        "id" => agent.id,
        "name" => "Bender Bot",
        "owner" => "David",
        "delivery_id" => 123
      }
    ), times: 1
  end

  test "agent key renders null owner for ownerless agents" do
    message = messages(:first)
    agent = agents(:bender_agent)
    agent.update_columns(owner_id: nil)

    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    webhooks(:bender).deliver(message, agent: agent, delivery_id: 7)

    assert_requested :post, webhooks(:bender).url, body: hash_including(
      "agent" => hash_including("owner" => nil, "delivery_id" => 7)
    ), times: 1
  end
end
