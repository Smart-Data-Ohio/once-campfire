require "application_system_test_case"

class BoardsTest < ApplicationSystemTestCase
  setup do
    @agent_user = User.create_bot!(name: "Board Agent")
    @agent = @agent_user.create_agent!(kind: :workspace, owner: users(:david))

    sign_in "david@37signals.com"
    join_room rooms(:designers)
  end

  test "boards carry posts from creation to result with live rows" do
    within("section[aria-labelledby='boards-heading']") do
      find("a[aria-label='New board']").click
    end
    fill_in "room[name]", with: "Launch"
    find("li[data-value='board agent'] label.switch").click
    find("button.btn--reversed").click

    assert_selector ".board__header h1", text: "Launch"
    assert_selector "#board_rooms .board-room", text: "Launch"
    board = Rooms::Board.last
    AgentGrant.create!(agent: @agent, room: board, granted_by: users(:david), capability: "post_messages")

    click_link "New post"
    fill_in "Title", with: "Ship the launch"
    fill_in "thread[first_message]", with: "Everything must go out on Friday."
    select "Board Agent", from: "Owner"
    fill_in "bug, api", with: "launch, api"
    click_button "Create post"

    assert_selector ".board-post__header h1", text: "Ship the launch"
    post = ChannelThread.last
    assert_selector ".board-post__facts", text: /Board Agent/
    assert_selector ".board-post__facts .agent-badge", text: "agent"
    assert_selector ".board-tag", text: "launch"
    assert_selector ".board-tag", text: "api"
    assert_selector ".board-post__messages", text: "Everything must go out on Friday."

    find(".board-post__result summary", text: "Edit result").click
    fill_in "Result in Markdown", with: "## Shipped on Friday"
    click_button "Save result"
    assert_selector ".board-post__result-body", text: "Shipped on Friday"
    assert_selector ".board-post__history", text: /David updated the result/

    using_session("List viewer") do
      sign_in "david@37signals.com"
      visit room_path(board)
      wait_for_cable_connection
      assert_selector "##{ActionView::RecordIdentifier.dom_id(post, :board_row)} .board-row__status", text: "Planned"
    end

    find(".board-post__work summary", text: "Update work").click
    select "In progress", from: "Work status"
    click_button "Save status"
    assert_selector ".board-post__facts", text: /In progress/

    using_session("List viewer") do
      assert_selector "##{ActionView::RecordIdentifier.dom_id(post, :board_row)} .board-row__status",
        text: "In progress", wait: BROADCAST_WAIT
      click_link "Board"
      assert_selector ".board__column[aria-label='In progress']", text: "Ship the launch"
      assert_selector ".board__column[aria-label='Planned'] .board-row", count: 0
    end
  end

  test "a non-member cannot open the board" do
    board = Rooms::Board.create_for({ name: "Secret", creator: users(:david) }, users: [ users(:david) ])

    using_session("Stranger") do
      sign_in "kevin@37signals.com"
      visit room_path(board)

      assert_no_selector ".board"
      assert_no_selector ".board-post"
      assert_not_equal room_path(board), current_path
    end
  end
end
