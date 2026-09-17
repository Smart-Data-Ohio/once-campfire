require "test_helper"

class Agents::MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
  end

  test "replies inside a channel thread" do
    thread = create_thread!(room: @room, creator: users(:david))

    assert_difference -> { thread.messages.count }, 1 do
      post room_agent_messages_url(@room),
        params: { thread_id: thread.id,
          message: { markdown_source: "On it.", client_message_id: "agent-thread-reply" } }.to_json,
        headers: bearer_headers
    end

    assert_response :created
    message = thread.messages.sole
    assert_equal @bot.id, message.creator_id
    assert_equal "On it.", message.plain_text_body
    assert_equal thread.id, response.parsed_body["thread_id"]
    assert_equal message.id, response.parsed_body["id"]

    posted = @agent.agent_events.where(event_type: "posted").last
    assert_equal message.id, posted.message_id
    assert_equal thread.id, posted.metadata["thread_id"]
  end

  test "replies inside a board post" do
    board = Rooms::Board.create_for({ name: "Launch", creator: users(:david) },
      users: [ users(:david) ])
    board.memberships.grant_to(@bot)
    grant!(capability: "post_messages", room: board)
    post_thread = ChannelThread.create_board_post!(
      room: board, creator: users(:david), name: "Ship it", work_status: "planned")

    post room_agent_messages_url(board),
      params: { thread_id: post_thread.id,
        message: { markdown_source: "Picking this up." } }.to_json,
      headers: bearer_headers

    assert_response :created
    assert_equal "Picking this up.", post_thread.messages.sole.plain_text_body
    assert_equal post_thread.id, response.parsed_body["thread_id"]
  end

  test "root posts gain a null thread_id and a null posted thread_id" do
    post room_agent_messages_url(@room),
      params: { message: { body: "Hello", client_message_id: "agent-root-thread-id" } }.to_json,
      headers: bearer_headers

    assert_response :created
    assert response.parsed_body.key?("thread_id")
    assert_nil response.parsed_body["thread_id"]
    assert_nil @agent.agent_events.where(event_type: "posted").last.metadata["thread_id"]
  end

  test "is 404 for threads in another room or missing" do
    foreign = create_thread!(room: rooms(:designers), creator: users(:david))

    post room_agent_messages_url(@room),
      params: { thread_id: foreign.id, message: { markdown_source: "Intruder" } }.to_json,
      headers: bearer_headers
    assert_response :not_found

    post room_agent_messages_url(@room),
      params: { thread_id: 999_999, message: { markdown_source: "Ghost" } }.to_json,
      headers: bearer_headers
    assert_response :not_found
  end

  test "is 422 for locked threads" do
    thread = create_thread!(room: @room, creator: users(:david))
    thread.lock_conversation!

    assert_no_difference -> { thread.messages.count } do
      post room_agent_messages_url(@room),
        params: { thread_id: thread.id, message: { markdown_source: "Locked out" } }.to_json,
        headers: bearer_headers
    end

    assert_response :unprocessable_entity
    assert_equal "This thread is locked", response.parsed_body["error"]
  end

  test "reopens closed threads" do
    thread = create_thread!(room: @room, creator: users(:david))
    thread.close!

    post room_agent_messages_url(@room),
      params: { thread_id: thread.id, message: { markdown_source: "Reopening" } }.to_json,
      headers: bearer_headers

    assert_response :created
    assert_predicate thread.reload, :active?
  end

  test "requires post_messages for thread replies" do
    thread = create_thread!(room: @room, creator: users(:david))
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")

    post room_agent_messages_url(@room),
      params: { thread_id: thread.id, message: { markdown_source: "Denied" } }.to_json,
      headers: bearer_headers

    assert_response :forbidden
    assert_equal "Forbidden: agent lacks post_messages capability", response.parsed_body["error"]
  end

  test "is 404 for rooms the agent is not a member of" do
    grant!(capability: "post_messages")
    thread = create_thread!(room: rooms(:designers), creator: users(:david))

    post room_agent_messages_url(rooms(:designers)),
      params: { thread_id: thread.id, message: { markdown_source: "Intruder" } }.to_json,
      headers: bearer_headers

    assert_response :not_found
  end

  test "rejects session and bot-key requests" do
    thread = create_thread!(room: @room, creator: users(:david))

    sign_in :david
    post room_agent_messages_url(@room),
      params: { thread_id: thread.id, message: { markdown_source: "Human" } }
    assert_response :forbidden
    assert_equal bearer_token_error, response.parsed_body["error"]
    delete session_url

    post room_agent_messages_url(@room, bot_key: @bot.bot_key),
      params: { thread_id: thread.id, message: { markdown_source: "Legacy" } }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "thread replies generate mention and reply events like root posts" do
    other = create_agent_in(@room, name: "Thread Loop Bot")
    thread = create_thread!(room: @room, creator: users(:david))

    post room_agent_messages_url(@room),
      params: { thread_id: thread.id,
        message: { markdown_source: "Hey @[Thread Loop Bot], take a look." } }.to_json,
      headers: bearer_headers
    assert_response :created

    mention = other.agent_events.where(event_type: "mention").last
    assert_equal thread.messages.sole.id, mention.message_id

    other_message = thread.post_message!(creator: other.user,
      attributes: { markdown_source: "Looking now.", client_message_id: "thread-loop-seed" })

    post room_agent_messages_url(@room),
      params: { thread_id: thread.id,
        message: { markdown_source: "Thanks!", reply_to_message_id: other_message.id } }.to_json,
      headers: bearer_headers
    assert_response :created

    reply = other.agent_events.where(event_type: "reply").last
    assert_equal thread.messages.last.id, reply.message_id
  end

  test "human thread messages mentioning the agent reach its event feed" do
    thread = create_thread!(room: @room, creator: users(:david))
    ThreadMembership.join!(thread, @bot)

    thread.post_message!(creator: users(:david),
      attributes: { markdown_source: "Hey @[Bender Bot], help here." })

    get agents_events_url, headers: bearer_headers

    assert_response :success
    assert_equal [ "mention" ], response.parsed_body.map { |row| row["event_type"] }
  end

  test "thread replies accept drive file ids" do
    thread = create_thread!(room: @room, creator: users(:david))

    post room_agent_messages_url(@room),
      params: { thread_id: thread.id,
        message: { markdown_source: "See this", drive_file_ids: [ "1AbcDefGhIj" ] } }.to_json,
      headers: bearer_headers

    assert_response :created
    assert_equal [ "1AbcDefGhIj" ], thread.messages.sole.drive_attachments.map(&:file_id)
    assert_equal [ "1AbcDefGhIj" ],
      response.parsed_body["drive_attachments"].map { |entry| entry["file_id"] }
  end

  test "invalid thread replies render errors" do
    thread = create_thread!(room: @room, creator: users(:david))
    root = @room.messages.create!(creator: users(:david), body: "Root", client_message_id: "thread-invalid-root")

    post room_agent_messages_url(@room),
      params: { thread_id: thread.id, message: { markdown_source: "  " } }.to_json,
      headers: bearer_headers
    assert_response :unprocessable_entity

    post room_agent_messages_url(@room),
      params: { thread_id: thread.id,
        message: { markdown_source: "Wrong target", reply_to_message_id: root.id } }.to_json,
      headers: bearer_headers
    assert_response :unprocessable_entity

    assert_empty thread.messages
  end

  private
    def grant!(capability:, room: nil)
      AgentGrant.create!(agent: @agent, room: room, granted_by: users(:david), capability: capability)
    end

    def bearer_headers
      { "Authorization" => "Bearer #{@secret}", "Content-Type" => "application/json" }
    end

    def bearer_token_error
      [ "Forbidden: Bearer", "agent", "token required" ].join(" ")
    end

    def create_agent_in(room, name:)
      bot = User.create_bot!(name: name)
      agent = bot.create_agent!(kind: :workspace, owner: users(:david))
      room.memberships.grant_to(bot)
      agent
    end

    def create_thread!(room:, creator:)
      thread = ChannelThread.create!(room: room, creator: creator, name: "Agent thread")
      ThreadMembership.join!(thread, creator)
      thread
    end
end
