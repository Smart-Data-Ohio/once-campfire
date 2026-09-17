require "test_helper"

class Agents::WorkPayloadTest < ActiveSupport::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")
  end

  test "carries the full work shape for a channel thread" do
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Payload work")
    ThreadMembership.join!(thread, users(:david))
    thread.update_work!(actor: users(:david), work_status: "in_progress", work_owner_id: @bot.id)
    thread.update_result!(actor: users(:david), markdown: "## Outcome")

    payload = Agents::WorkPayload.for(thread.reload)

    assert_equal thread.id, payload[:id]
    assert_equal @room.id, payload[:room_id]
    assert_nil payload[:board_id]
    assert_nil payload[:board_name]
    assert_equal "Payload work", payload[:title]
    assert_equal "in_progress", payload[:work_status]
    assert_equal({ id: @bot.id, name: "Bender Bot", agent: true }, payload[:owner])
    assert_equal [], payload[:tags]
    assert_equal "## Outcome", payload[:result]
    assert_equal thread.result_updated_at.utc, payload[:result_updated_at]
    assert_nil payload[:run_url]
    assert_equal room_path(@room, thread: thread.id), payload[:url]
    assert_equal thread.updated_at.utc, payload[:updated_at]
    assert_equal [], payload[:links]
  end

  test "marks human owners and null owners" do
    human_thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Human work")
    ThreadMembership.join!(human_thread, users(:david))
    human_thread.update_work!(actor: users(:david), work_status: "planned", work_owner_id: users(:jason).id)

    assert_equal({ id: users(:jason).id, name: "Jason", agent: false },
      Agents::WorkPayload.for(human_thread)[:owner])

    unowned_thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Unowned work")
    ThreadMembership.join!(unowned_thread, users(:david))
    unowned_thread.update_work!(actor: users(:david), work_status: "planned")

    assert_nil Agents::WorkPayload.for(unowned_thread)[:owner]
  end

  test "carries board identity, tags, run_url, and links for a post" do
    board = Rooms::Board.create_for({ name: "Launch", creator: users(:david) },
      users: [ users(:david) ])
    board.memberships.grant_to(@bot)
    AgentGrant.create!(agent: @agent, room: board, granted_by: users(:david), capability: "post_messages")
    post = ChannelThread.create_board_post!(
      room: board, creator: @bot, name: "Board payload", work_status: "in_progress",
      owner_id: @bot.id, tags: "api, launch", run_url: "https://example.com/runs/1",
      first_message: "Brief.")

    payload = Agents::WorkPayload.for(post.reload)

    assert_equal board.id, payload[:board_id]
    assert_equal "Launch", payload[:board_name]
    assert_equal %w[ api launch ], payload[:tags]
    assert_equal "https://example.com/runs/1", payload[:run_url]
    assert_equal room_path(board, thread: post.id), payload[:url]
  end
end
