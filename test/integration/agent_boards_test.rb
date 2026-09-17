require "test_helper"

class AgentBoardsTest < ActionDispatch::IntegrationTest
  setup do
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    @board = Rooms::Board.create_for({ name: "Launch", creator: users(:david) },
      users: [ users(:david), users(:kevin) ])
    @board.memberships.grant_to(@bot)
    %w[ read_messages post_messages manage_threads ].each do |capability|
      AgentGrant.create!(agent: @agent, room: @board, granted_by: users(:david), capability: capability)
    end
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
  end

  test "an agent post flows from creation through reply to result" do
    # The agent files a post with a brief: the human sees it in the board
    # index with the agent as owner, the first message in the discussion,
    # and the assignment in Work history.
    post room_agent_posts_url(@board), params: {
      title: "Ship the launch", body: "Everything goes out Friday.",
      tags: "launch", run_url: "https://example.com/runs/11"
    }.to_json, headers: bearer_headers
    assert_response :created
    thread = ChannelThread.find(response.parsed_body["id"])

    sign_in :david
    get room_url(@board)
    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(thread, :board_row)}", text: /Ship the launch/
    assert_select "##{ActionView::RecordIdentifier.dom_id(thread, :board_row)} .board-row__owner",
      text: /Bender Bot/
    assert_select "##{ActionView::RecordIdentifier.dom_id(thread, :board_row)} .agent-badge",
      text: "agent"

    get room_thread_url(@board, thread)
    assert_response :success
    assert_select ".board-post__messages", text: /Everything goes out Friday\./
    assert_select ".board-post__run a[href='https://example.com/runs/11']", text: /Run/

    get room_thread_url(@board, thread, format: :json)
    assert_response :success
    assignment = response.parsed_body.dig("thread", "work_history").find do |entry|
      entry["event_type"] == "work_assignment"
    end
    assert_equal @bot.id, assignment.dig("after", "owner", "id")
    assert_equal "Bender Bot", assignment.dig("actor", "name")

    # The human dispatches follow-up work to the agent with a brief; the
    # agent replies in the discussion and writes the pinned result, and
    # the human creator's inbox carries the work_update item. (A result
    # edit notifies the post's creator and owner, so the notified human
    # here is the creator who assigned the agent.)
    post room_threads_url(@board), params: {
      thread: { name: "Follow-up fixes", first_message: "Small fixes before Friday.",
        work_owner_id: @bot.id }
    }
    assert_response :redirect
    follow_up = ChannelThread.ordered.first
    delete session_url

    post room_agent_messages_url(@board),
      params: { thread_id: follow_up.id,
        message: { markdown_source: "Halfway there." } }.to_json,
      headers: bearer_headers
    assert_response :created

    put "/agents/work/#{follow_up.id}/result",
      params: { markdown: "## Shipped on Friday" }.to_json,
      headers: bearer_headers
    assert_response :success

    sign_in :david
    get room_thread_url(@board, follow_up)
    assert_response :success
    assert_select ".board-post__messages", text: /Halfway there\./
    assert_select ".board-post__result-body", text: /Shipped on Friday/
    assert_select ".board-post__history", text: /Bender Bot updated the result/

    result_event = follow_up.work_thread_events.ordered.find_by!(event_type: "result_updated")
    item = ActivityItem.find_by!(user: users(:david), source: result_event)
    assert_equal "work_update", item.event_type

    get activity_items_url
    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(item)}"
  end

  private
    def bearer_headers
      { "Authorization" => "Bearer #{@secret}", "Content-Type" => "application/json" }
    end
end
