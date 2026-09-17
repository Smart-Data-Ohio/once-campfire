require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "smartfire.test"

    sign_in :david
    @room = rooms(:watercooler)
    @messages = @room.messages.ordered.to_a
  end

  test "index returns the last page by default" do
    get room_messages_url(@room)

    assert_response :success
    ensure_messages_present @messages.last
  end

  test "index returns a page before the specified message" do
    get room_messages_url(@room, before: @messages.third)

    assert_response :success
    ensure_messages_present @messages.first, @messages.second
    ensure_messages_not_present @messages.third, @messages.fourth, @messages.fifth
  end

  test "index returns a page after the specified message" do
    get room_messages_url(@room, after: @messages.third)

    assert_response :success
    ensure_messages_present @messages.fourth, @messages.fifth
    ensure_messages_not_present @messages.first, @messages.second, @messages.third
  end

  test "index returns no_content when there are no messages" do
    @room.messages.destroy_all

    get room_messages_url(@room)

    assert_response :no_content
  end

  test "get renders a single message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    get room_message_url(@room, message)

    assert_response :success
  end

  test "creating a message broadcasts the message to the room" do
    post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "New one", client_message_id: 999 } }

    assert_rendered_turbo_stream_broadcast @room, :messages, action: "append", target: [ @room, :messages ] do
      assert_select ".message__body", text: /New one/
      assert_copy_link_button room_at_message_url(@room, Message.last, host: "smartfire.test")
    end
  end

  test "broadcast message actions preserve a nonstandard request port" do
    origin = "http://smartfire.test:3443"
    post "#{origin}#{room_messages_path(@room, format: :turbo_stream)}", params: {
      message: { markdown_source: "A live message", client_message_id: "broadcast-port" }
    }

    assert_rendered_turbo_stream_broadcast @room, :messages, action: "append", target: [ @room, :messages ] do
      assert_select "[data-message-actions-metadata-url-value='#{origin}#{actions_room_message_path(@room, Message.last)}']"
      assert_copy_link_button "#{origin}#{room_at_message_path(@room, Message.last)}"
    end
  end

  test "creating a Markdown message preserves its source and derives the rich body" do
    source = "# Release\n\n**Ready**"

    post room_messages_url(@room, format: :turbo_stream), params: {
      message: { body: "<script>wrong source</script>", markdown_source: source, client_message_id: 999 }
    }

    message = Message.last
    assert_response :success
    assert_equal source, message.markdown_source
    assert_equal "Release\n\nReady", message.plain_text_body
    assert_match %r{<h1>Release</h1>}, message.body.body.to_html
    assert_no_match /script/, message.body.body.to_html
  end

  test "preview renders the same safe Markdown without writing" do
    assert_no_difference -> { Message.count } do
      post preview_room_messages_url(@room), params: {
        message: { markdown_source: "## Preview\n\n<script>x</script>\n\n- [x] @[David]" }
      }, as: :json
    end

    assert_response :success
    html = response.parsed_body.fetch("html")
    assert_match %r{<h2>Preview</h2>}, html
    assert_match %r{<input type="checkbox" checked="" disabled="disabled">}, html
    assert_match %r{<div class="mention mention--user-#{users(:david).id}"}, html
    assert_match %r{data-user-id="#{users(:david).id}"}, html
    assert_no_match /<script/, html
  end

  test "preview requires room membership" do
    sign_in :kevin

    assert_raises ActiveRecord::RecordNotFound do
      post preview_room_messages_url(@room), params: { message: { markdown_source: "No access" } }
    end
  end

  test "preview rejects oversized Markdown without parsing or writing it" do
    assert_no_difference -> { Message.count } do
      post preview_room_messages_url(@room), params: {
        message: { markdown_source: "x" * (Message::Markdown::SOURCE_LIMIT + 1) }
      }
    end

    assert_response :unprocessable_content
    assert_match(/limited/, response.parsed_body.fetch("error"))
  end

  test "preview is protected against cross-site form submissions" do
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_raises ActionController::InvalidAuthenticityToken do
      post preview_room_messages_url(@room), params: { message: { markdown_source: "No token" } }
    end
  ensure
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  test "creating a message broadcasts unread room to each member" do
    @room.users.each do |member|
      assert_broadcasts UnreadRoomsChannel.stream_name_for(member.id), 1 do
        post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "New one #{member.id}", client_message_id: member.id } }
      end
    end
  end

  test "creating a message doesn't broadcast unread room to non-members" do
    outsiders = User.where.not(id: @room.users.map(&:id))
    assert outsiders.any?, "need someone outside the room for this test to mean anything"

    outsiders.each do |outsider|
      assert_no_broadcasts UnreadRoomsChannel.stream_name_for(outsider.id) do
        post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "New one", client_message_id: 999 } }
      end
    end
  end

  test "update updates a message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    Turbo::StreamsChannel.expects(:broadcast_replace_to).once
    put room_message_url(@room, message), params: { message: { body: "Updated body" } }

    assert_redirected_to room_message_url(@room, message)
    assert_equal "Updated body", message.reload.plain_text_body
  end

  test "updating a Markdown message preserves exact new source" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "**Before**", client_message_id: "markdown-update")
    source = "## After\n\n`code`"

    Turbo::StreamsChannel.expects(:broadcast_replace_to).once
    put room_message_url(@room, message), params: { message: { markdown_source: source } }

    assert_redirected_to room_message_url(@room, message)
    assert_equal source, message.reload.markdown_source
    assert_equal "After\n\ncode", message.plain_text_body
  end

  test "a legacy body update clears stale Markdown mode" do
    message = @room.messages.create!(creator: users(:david), markdown_source: "**Before**", client_message_id: "markdown-to-rich")

    Turbo::StreamsChannel.expects(:broadcast_replace_to).once
    put room_message_url(@room, message), params: { message: { body: "Legacy again" } }

    assert_redirected_to room_message_url(@room, message)
    assert_nil message.reload.markdown_source
    assert_equal "Legacy again", message.plain_text_body
  end

  test "admin cannot update a message belonging to another user" do
    message = @room.messages.where(creator: users(:jason)).first

    assert_no_changes -> { message.reload.plain_text_body } do
      put room_message_url(@room, message), params: { message: { body: "Updated body" } }
    end

    assert_response :forbidden
  end

  test "destroy destroys a message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    assert_difference -> { Message.count }, -1 do
      Turbo::StreamsChannel.expects(:broadcast_remove_to).once
      delete room_message_url(@room, message, format: :turbo_stream)
      assert_response :success
    end
  end

  test "admin destroy destroys a message belonging to another user" do
    assert users(:david).administrator?
    message = @room.messages.where(creator: users(:jason)).first

    assert_difference -> { Message.count }, -1 do
      Turbo::StreamsChannel.expects(:broadcast_remove_to).once
      delete room_message_url(@room, message, format: :turbo_stream)
      assert_response :success
    end
  end

  test "ensure non-admin can't update a message belonging to another user" do
    sign_in :jz
    assert_not users(:jz).administrator?

    room = rooms(:designers)
    message = room.messages.where(creator: users(:jason)).first

    put room_message_url(room, message), params: { message: { body: "Updated body" } }
    assert_response :forbidden
  end

  test "ensure non-admin can't destroy a message belonging to another user" do
    sign_in :jz
    assert_not users(:jz).administrator?

    room = rooms(:designers)
    message = room.messages.where(creator: users(:jason)).first

    delete room_message_url(room, message, format: :turbo_stream)
    assert_response :forbidden
  end

  test "mentioning a bot triggers a webhook" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    assert_enqueued_jobs 1, only: Agent::DeliveryJob do
      post room_messages_url(@room, format: :turbo_stream), params: { message: {
        body: "<div>Hey #{mention_attachment_for(:bender)}</div>", client_message_id: 999 } }
    end
  end

  test "mentioning a bot from Markdown triggers a webhook" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    assert_enqueued_jobs 1, only: Agent::DeliveryJob do
      post room_messages_url(@room, format: :turbo_stream), params: { message: {
        markdown_source: "Hey @[Bender Bot]", client_message_id: 999 } }
    end
  end

  test "mentioning an agent-backed bot skips the legacy webhook job" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    assert_no_enqueued_jobs only: Bot::WebhookJob do
      post room_messages_url(@room, format: :turbo_stream), params: { message: {
        markdown_source: "Hey @[Bender Bot]", client_message_id: "agent-only" } }
    end
  end

  test "mentioning an agent-backed bot posts exactly one webhook with the agent key" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    post room_messages_url(@room, format: :turbo_stream), params: { message: {
      markdown_source: "Hey @[Bender Bot]", client_message_id: "agent-once" } }

    perform_enqueued_jobs only: Agent::DeliveryJob
    perform_enqueued_jobs only: Bot::WebhookJob

    assert_requested :post, webhooks(:bender).url, times: 1
    assert_requested :post, webhooks(:bender).url,
      body: hash_including("agent" => hash_including("id" => agents(:bender_agent).id)), times: 1
  end

  test "revoked agent delivery posts no webhook" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    grant = AgentGrant.create!(agent: agents(:bender_agent), room: @room, granted_by: users(:david), capability: "read_messages")

    post room_messages_url(@room, format: :turbo_stream), params: { message: {
      markdown_source: "Hey @[Bender Bot]", client_message_id: "agent-revoked" } }

    grant.revoke!
    perform_enqueued_jobs only: Agent::DeliveryJob
    perform_enqueued_jobs only: Bot::WebhookJob

    assert_not_requested :post, webhooks(:bender).url
  end

  test "mentioning a bot without an agent row still uses the legacy webhook" do
    bot = User.create_bot!(name: "Legacy Bot", webhook_url: "https://example.test/legacy-hook")
    @room.memberships.grant_to(bot)
    WebMock.stub_request(:post, bot.webhook.url).to_return(status: 200)

    assert_enqueued_jobs 1, only: Bot::WebhookJob do
      assert_no_enqueued_jobs only: Agent::DeliveryJob do
        post room_messages_url(@room, format: :turbo_stream), params: { message: {
          markdown_source: "Hey @[Legacy Bot]", client_message_id: "legacy-only" } }
      end
    end

    perform_enqueued_jobs only: Agent::DeliveryJob
    perform_enqueued_jobs only: Bot::WebhookJob

    assert_requested :post, bot.webhook.url, body: hash_excluding("agent"), times: 1
  end

  private
    def ensure_messages_present(*messages, count: 1)
      messages.each do |message|
        assert_select "#" + dom_id(message), count:
      end
    end

    def ensure_messages_not_present(*messages)
      ensure_messages_present *messages, count: 0
    end

    def assert_copy_link_button(url)
      assert_select "[data-message-actions-permalink-url-value='#{url}']"
    end
end
