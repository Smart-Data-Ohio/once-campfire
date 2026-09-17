require "test_helper"

class Users::SidebarsBoardsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @board = Rooms::Board.create_for({ name: "Launch", creator: users(:david) },
      users: [ users(:david), users(:jz) ])
  end

  test "boards list in their own section between channels and voice" do
    get user_sidebar_url
    assert_response :success

    channels_at = response.body.index("channels-heading")
    boards_at = response.body.index("boards-heading")
    voice_at = response.body.index("voice-heading")
    assert channels_at < boards_at
    assert boards_at < voice_at

    assert_select "#board_rooms .board-room", text: "Launch"
    assert_select "#shared_rooms .board-room", count: 0
    assert_select "a[aria-label='New board'][href='#{new_rooms_board_path}']"
  end

  test "board rows show unread state and new members see the board" do
    ChannelThread.create!(room: @board, creator: users(:jz), name: "News", work_status: "planned")

    get user_sidebar_url
    assert_select "#board_rooms .board-room.unread", text: /Launch/

    sign_in :jz
    get user_sidebar_url
    assert_select "#board_rooms .board-room", text: "Launch"
    assert_select "#board_rooms .board-room.unread", count: 0
  end

  test "new board control follows room creation permissions" do
    accounts(:signal).settings.restrict_room_creation_to_administrators = true
    accounts(:signal).save!

    sign_in :jz
    get user_sidebar_url
    assert_select "a[aria-label='New board']", count: 0

    sign_in :david
    get user_sidebar_url
    assert_select "a[aria-label='New board']", count: 1
  end
end
