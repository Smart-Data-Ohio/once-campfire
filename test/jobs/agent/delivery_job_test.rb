require "test_helper"

class Agent::DeliveryJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
  end

  test "mentioning an agent enqueues delivery and performing marks it delivered" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    assert_enqueued_jobs 1, only: Agent::DeliveryJob do
      create_mentioning_message(@room, @bot, creator: users(:david))
    end

    event = @agent.agent_events.deliverable.last
    assert_equal "mention", event.event_type
    assert_equal "pending", event.outcome
    assert_equal 0, event.hop

    perform_enqueued_jobs only: Agent::DeliveryJob

    assert_equal "delivered", event.reload.outcome
  end

  test "delivery posts the webhook with the additive agent key" do
    WebMock.stub_request(:post, webhooks(:bender).url)
      .with(body: hash_including(agent: hash_including("id" => @agent.id)))
      .to_return(status: 200)

    message = create_mentioning_message(@room, @bot, creator: users(:david))
    event = @agent.agent_events.deliverable.last
    perform_enqueued_jobs only: Agent::DeliveryJob

    assert_equal "delivered", event.reload.outcome
    assert_requested :post, webhooks(:bender).url, body: hash_including(
      "agent" => {
        "id" => @agent.id,
        "name" => "Bender Bot",
        "owner" => "David",
        "delivery_id" => event.id
      }
    ), times: 1
    assert_equal message.id, event.message_id
  end

  test "delivery without a webhook still marks the row delivered" do
    webhooks(:bender).destroy!

    create_mentioning_message(@room, @bot, creator: users(:david))
    event = @agent.agent_events.deliverable.last
    perform_enqueued_jobs only: Agent::DeliveryJob

    assert_equal "delivered", event.reload.outcome
  end

  test "revoked at perform time writes a suppression row" do
    grant = AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")

    create_mentioning_message(@room, @bot, creator: users(:david))
    event = @agent.agent_events.deliverable.last
    assert_equal "pending", event.outcome

    grant.revoke!
    perform_enqueued_jobs only: Agent::DeliveryJob

    assert_equal "suppressed", event.reload.outcome
    suppression = @agent.agent_events.where(event_type: "delivery_suppressed_revoked").last
    assert suppression.present?
    assert_equal "suppressed", suppression.outcome
    assert_equal event.message_id, suppression.message_id
  end

  test "membership removed before delivery writes a suppression row" do
    create_mentioning_message(@room, @bot, creator: users(:david))
    event = @agent.agent_events.deliverable.last

    memberships(:bender_watercooler).destroy!
    perform_enqueued_jobs only: Agent::DeliveryJob

    assert_equal "suppressed", event.reload.outcome
    assert @agent.agent_events.where(event_type: "delivery_suppressed_revoked").exists?
  end

  test "performing the same event twice posts the webhook only once" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    create_mentioning_message(@room, @bot, creator: users(:david))
    event = @agent.agent_events.deliverable.last

    Agent::DeliveryJob.perform_now(event.id)
    assert_equal "delivered", event.reload.outcome

    Agent::DeliveryJob.perform_now(event.id)

    assert_equal "delivered", event.reload.outcome
    assert_requested :post, webhooks(:bender).url, times: 1
  end

  test "a job that loses the delivery race exits without posting" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    create_mentioning_message(@room, @bot, creator: users(:david))
    event = @agent.agent_events.deliverable.last

    # Another job claims the row after our checks pass but before our claim.
    Agent::Delivery.stubs(:rate_limited?).with { event.update_columns(outcome: "delivered"); true }.returns(false)

    Agent::DeliveryJob.perform_now(event.id)

    assert_not_requested :post, webhooks(:bender).url
  end

  test "a job that loses the suppression race writes no duplicate row" do
    create_mentioning_message(@room, @bot, creator: users(:david))
    event = @agent.agent_events.deliverable.last

    # Another job claims the row while our suppression decision is in flight.
    Agent::Delivery.stubs(:rate_limited?).with { event.update_columns(outcome: "suppressed"); true }.returns(true)

    Agent::DeliveryJob.perform_now(event.id)

    assert_empty @agent.agent_events.where(event_type: "delivery_suppressed_rate_limit")
  end

  test "message deleted before delivery suppresses without crashing or posting" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    create_mentioning_message(@room, @bot, creator: users(:david))
    event = @agent.agent_events.deliverable.last
    event.message.destroy!

    perform_enqueued_jobs only: Agent::DeliveryJob

    assert_equal "suppressed", event.reload.outcome
    assert_not_requested :post, webhooks(:bender).url
  end

  test "rate limit drops the 21st delivery with a suppression row and no job" do
    20.times do |i|
      @room.messages.create!(
        creator: users(:david), body: "Ping #{i} #{mention_attachment_for(:bender)}",
        client_message_id: "rate-#{i}"
      )
    end
    assert_equal 20, @agent.agent_events.deliverable.count

    assert_no_enqueued_jobs only: Agent::DeliveryJob do
      @room.messages.create!(
        creator: users(:david), body: "Ping over #{mention_attachment_for(:bender)}",
        client_message_id: "rate-over"
      )
    end

    assert_equal 20, @agent.agent_events.deliverable.count
    suppression = @agent.agent_events.where(event_type: "delivery_suppressed_rate_limit").last
    assert suppression.present?
    assert_equal "suppressed", suppression.outcome
  end

  test "rate limit is per agent per room" do
    other_agent = create_agent_in(@room, name: "Throttle Bot")
    other_bot = other_agent.user

    20.times do |i|
      @room.messages.create!(
        creator: users(:david),
        body: "Ping #{i} #{mention_attachment_for(:bender)}",
        client_message_id: "rate-own-#{i}"
      )
    end

    # The other agent is unaffected by Bender's volume.
    assert_enqueued_jobs 1, only: Agent::DeliveryJob do
      @room.messages.create!(
        creator: users(:david),
        markdown_source: "Hey @[#{other_bot.name}]",
        client_message_id: "rate-other-1"
      )
    end
    assert_equal 1, other_agent.agent_events.deliverable.count
  end

  test "reply to an agent's message creates a reply event" do
    agent_message = @room.messages.create!(creator: @bot, body: "Agent here", client_message_id: "reply-parent")

    assert_enqueued_jobs 1, only: Agent::DeliveryJob do
      @room.messages.create!(
        creator: users(:david), body: "Answering", reply_to_message: agent_message,
        client_message_id: "reply-child"
      )
    end

    event = @agent.agent_events.deliverable.last
    assert_equal "reply", event.event_type
    assert_equal agent_message.creator_id, @bot.id
  end

  test "a message that both mentions and replies records a single reply event" do
    agent_message = @room.messages.create!(creator: @bot, body: "Agent here", client_message_id: "both-parent")

    assert_difference -> { @agent.agent_events.deliverable.count }, 1 do
      @room.messages.create!(
        creator: users(:david),
        body: "Hey #{mention_attachment_for(:bender)}",
        reply_to_message: agent_message,
        client_message_id: "both-child"
      )
    end

    assert_equal "reply", @agent.agent_events.deliverable.last.event_type
  end

  test "direct room messages create direct_message events" do
    dm = rooms(:bender_and_kevin)

    assert_enqueued_jobs 1, only: Agent::DeliveryJob do
      dm.messages.create!(creator: users(:kevin), body: "Hello bot", client_message_id: "dm-1")
    end

    event = @agent.agent_events.deliverable.last
    assert_equal "direct_message", event.event_type
    assert_equal dm.id, event.room_id
  end

  test "agent posting writes a posted row" do
    assert_difference -> { @agent.agent_events.where(event_type: "posted").count }, 1 do
      @room.messages.create!(creator: @bot, body: "Posting", client_message_id: "posted-1")
    end

    posted = @agent.agent_events.where(event_type: "posted").last
    assert_equal "delivered", posted.outcome
  end

  test "agent never receives its own messages" do
    assert_no_difference -> { @agent.agent_events.deliverable.count } do
      @room.messages.create!(
        creator: @bot, body: "Talking #{mention_attachment_for(:bender)}",
        client_message_id: "self-1"
      )
    end
  end

  test "bot without an agent row receives no events" do
    @agent.destroy!

    assert_no_difference -> { AgentEvent.count } do
      @room.messages.create!(
        creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
        client_message_id: "no-agent-1"
      )
    end
  end

  test "hop limit suppresses a chain that reaches hop 3" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    agent_b = create_agent_in(@room, name: "Hop Bot B")
    bot_b = agent_b.user

    # Human mentions A at hop 0.
    m1 = @room.messages.create!(
      creator: users(:david), markdown_source: "Hey @[#{@bot.name}]", client_message_id: "hop-m1"
    )
    perform_enqueued_jobs only: Agent::DeliveryJob
    assert_equal 0, @agent.agent_events.deliverable.last.hop

    # A replies mentioning B at hop 1.
    m2 = @room.messages.create!(
      creator: @bot, markdown_source: "Hey @[#{bot_b.name}]", reply_to_message: m1,
      client_message_id: "hop-m2"
    )
    perform_enqueued_jobs only: Agent::DeliveryJob
    assert_equal 1, agent_b.agent_events.deliverable.last.hop

    # B replies mentioning A at hop 2.
    m3 = @room.messages.create!(
      creator: bot_b, markdown_source: "Hey @[#{@bot.name}]", reply_to_message: m2,
      client_message_id: "hop-m3"
    )
    perform_enqueued_jobs only: Agent::DeliveryJob
    assert_equal 2, @agent.agent_events.deliverable.last.hop

    # A replies mentioning B at hop 3: suppressed, not queued.
    assert_no_enqueued_jobs only: Agent::DeliveryJob do
      @room.messages.create!(
        creator: @bot, markdown_source: "Hey @[#{bot_b.name}] again", reply_to_message: m3,
        client_message_id: "hop-m4"
      )
    end

    suppression = agent_b.agent_events.where(event_type: "delivery_suppressed_hop_limit").last
    assert suppression.present?
    assert_equal "suppressed", suppression.outcome
    assert_equal 3, suppression.hop
  end

  test "replying to an old low-hop message does not reset the chain" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    agent_b = create_agent_in(@room, name: "Reply Bot B")
    bot_b = agent_b.user

    m1 = @room.messages.create!(
      creator: users(:david), markdown_source: "Hey @[#{@bot.name}]", client_message_id: "reply-hop-m1"
    )
    perform_enqueued_jobs only: Agent::DeliveryJob

    m2 = @room.messages.create!(
      creator: @bot, markdown_source: "Hey @[#{bot_b.name}]", reply_to_message: m1,
      client_message_id: "reply-hop-m2"
    )
    perform_enqueued_jobs only: Agent::DeliveryJob

    m3 = @room.messages.create!(
      creator: bot_b, markdown_source: "Hey @[#{@bot.name}]", reply_to_message: m2,
      client_message_id: "reply-hop-m3"
    )
    perform_enqueued_jobs only: Agent::DeliveryJob
    assert_equal 2, @agent.agent_events.deliverable.last.hop

    # Replying to the ancient hop-0 message still chains off the most recent
    # delivered event (hop 2), so this reaches hop 3 and is suppressed.
    assert_no_enqueued_jobs only: Agent::DeliveryJob do
      @room.messages.create!(
        creator: @bot, markdown_source: "Hey @[#{bot_b.name}] again", reply_to_message: m1,
        client_message_id: "reply-hop-m4"
      )
    end

    suppression = agent_b.agent_events.where(event_type: "delivery_suppressed_hop_limit").last
    assert suppression.present?
    assert_equal 3, suppression.hop
  end

  test "suppression rows are never hop triggers" do
    agent_b = create_agent_in(@room, name: "Suppression Bot B")
    @agent.agent_events.create!(
      event_type: "delivery_suppressed_hop_limit", room: @room,
      outcome: "suppressed", detail: "old cap", metadata: { "hop" => 3 }
    )

    assert_enqueued_jobs 1, only: Agent::DeliveryJob do
      @room.messages.create!(
        creator: @bot, markdown_source: "Hey @[#{agent_b.user.name}] fresh",
        client_message_id: "suppression-trigger"
      )
    end

    assert_equal 0, agent_b.agent_events.deliverable.last.hop
  end

  test "pending rows are never hop triggers" do
    agent_b = create_agent_in(@room, name: "Pending Bot B")
    create_mentioning_message(@room, @bot, creator: users(:david))
    assert_equal "pending", @agent.agent_events.deliverable.last.outcome

    @room.messages.create!(
      creator: @bot, markdown_source: "Hey @[#{agent_b.user.name}] fresh",
      client_message_id: "pending-trigger"
    )

    assert_equal 0, agent_b.agent_events.deliverable.last.hop
  end

  test "deliveries older than five minutes are not hop triggers" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    agent_b = create_agent_in(@room, name: "Window Bot B")
    create_mentioning_message(@room, @bot, creator: users(:david))
    perform_enqueued_jobs only: Agent::DeliveryJob
    @agent.agent_events.deliverable.last.update_columns(created_at: 6.minutes.ago)

    @room.messages.create!(
      creator: @bot, markdown_source: "Hey @[#{agent_b.user.name}] fresh",
      client_message_id: "window-trigger"
    )

    assert_equal 0, agent_b.agent_events.deliverable.last.hop
  end

  test "consecutive posts without new deliveries chain off the latest row" do
    agent_b = create_agent_in(@room, name: "Chain Bot B")

    @room.messages.create!(
      creator: @bot, markdown_source: "Hey @[#{agent_b.user.name}] one",
      client_message_id: "chain-one"
    )
    assert_equal 0, agent_b.agent_events.deliverable.last.hop

    @room.messages.create!(
      creator: @bot, markdown_source: "Hey @[#{agent_b.user.name}] two",
      client_message_id: "chain-two"
    )
    assert_equal 1, agent_b.agent_events.deliverable.last.hop
  end

  test "two agents mentioning each other stop at the hop limit with both suppressions" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    agent_b = create_agent_in(@room, name: "Loop Bot B")
    bot_b = agent_b.user
    bot_a = @bot

    # A starts the loop mentioning B.
    last = @room.messages.create!(
      creator: bot_a, markdown_source: "Hey @[#{bot_b.name}] start", client_message_id: "loop-m0"
    )
    perform_enqueued_jobs only: Agent::DeliveryJob

    # Alternate replies until the hop limit stops both directions.
    10.times do |i|
      sender, recipient = i.even? ? [ bot_b, bot_a ] : [ bot_a, bot_b ]
      last = @room.messages.create!(
        creator: sender, markdown_source: "Hey @[#{recipient.name}] #{i}", reply_to_message: last,
        client_message_id: "loop-m#{i + 1}"
      )
      perform_enqueued_jobs only: Agent::DeliveryJob

      break if @agent.agent_events.where(event_type: "delivery_suppressed_hop_limit").exists? &&
        agent_b.agent_events.where(event_type: "delivery_suppressed_hop_limit").exists?
    end

    assert @agent.agent_events.where(event_type: "delivery_suppressed_hop_limit").exists?,
      "expected a hop-limit suppression for agent A"
    assert agent_b.agent_events.where(event_type: "delivery_suppressed_hop_limit").exists?,
      "expected a hop-limit suppression for agent B"

    # No further deliveries are queued once suppressed at the limit.
    assert_no_enqueued_jobs only: Agent::DeliveryJob do
      @room.messages.create!(
        creator: bot_a, markdown_source: "Hey @[#{bot_b.name}] after", reply_to_message: last,
        client_message_id: "loop-after"
      )
    end
  end

  private
    def create_mentioning_message(room, bot, creator:)
      assert_equal users(:bender), bot, "this helper only mentions the fixture bot"
      room.messages.create!(
        creator: creator, body: "Hey #{mention_attachment_for(:bender)}",
        client_message_id: "mention-#{SecureRandom.hex(4)}"
      )
    end

    def create_agent_in(room, name:)
      bot = User.create_bot!(name: name)
      agent = bot.create_agent!(kind: :workspace, owner: users(:david))
      room.memberships.grant_to(bot)
      agent
    end
end
