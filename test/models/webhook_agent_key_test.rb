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

  test "agent delivery in a PR thread carries the pull_request object" do
    room = rooms(:watercooler)
    parent = room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "webhook-pr-parent"
    )
    pull_request = parent.github_pull_requests.first
    pull_request.update!(
      title: "Fix login", state: "open", base_branch: "main", head_branch: "shiny",
      review_decision: "approved", check_status: "passing",
      html_url: "https://github.com/rails/rails/pull/12"
    )
    thread = ChannelThread.create!(room: room, creator: users(:david), name: "PR chat", parent_message: parent)
    Github::PullRequestThread.create!(pull_request: pull_request, room: room, channel_thread: thread)
    reply = thread.post_message!(
      creator: users(:david), attributes: { markdown_source: "hey", client_message_id: "webhook-pr-reply" }
    )

    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    webhooks(:bender).deliver(reply, agent: agents(:bender_agent), delivery_id: 9)

    assert_requested :post, webhooks(:bender).url, body: hash_including(
      "pull_request" => {
        "url" => "https://github.com/rails/rails/pull/12",
        "owner" => "rails",
        "repo" => "rails",
        "number" => 12,
        "title" => "Fix login",
        "state" => "open",
        "head_branch" => "shiny",
        "base_branch" => "main",
        "review_decision" => "approved",
        "checks_state" => "passing"
      }
    ), times: 1
  end

  test "agent delivery outside PR threads carries a null pull_request" do
    room = rooms(:watercooler)
    parent = room.messages.create!(
      creator: users(:david), markdown_source: "ordinary starter",
      client_message_id: "webhook-null-parent"
    )
    thread = ChannelThread.create!(room: room, creator: users(:david), name: "Ordinary chat", parent_message: parent)
    reply = thread.post_message!(
      creator: users(:david), attributes: { markdown_source: "hey", client_message_id: "webhook-null-reply" }
    )
    room_message = room.messages.create!(
      creator: users(:david), markdown_source: "hey in the room",
      client_message_id: "webhook-null-room"
    )

    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    webhooks(:bender).deliver(reply, agent: agents(:bender_agent), delivery_id: 10)
    webhooks(:bender).deliver(room_message, agent: agents(:bender_agent), delivery_id: 11)

    assert_requested :post, webhooks(:bender).url, body: hash_including("pull_request" => nil), times: 2
  end
end
