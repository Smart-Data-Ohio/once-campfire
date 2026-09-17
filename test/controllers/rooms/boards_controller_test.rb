require "test_helper"

class Rooms::BoardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show redirects to get general show" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david) ])

    get rooms_board_url(room)
    assert_redirected_to room_url(room)
  end

  test "new" do
    get new_rooms_board_url
    assert_response :success
  end

  test "create" do
    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
    assert_turbo_stream_broadcasts [ users(:kevin), :rooms ], count: 1 do
    assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 1 do
      post rooms_boards_url, params: { room: { name: "Launch" }, user_ids: [ users(:david).id, users(:kevin).id, users(:jason).id ] }
    end
    end
    end

    new_room = Room.last
    assert_instance_of Rooms::Board, new_room
    assert_equal new_room.memberships.count, 3
    assert_redirected_to room_url(Room.last)
  end

  test "create prepends the board row into the boards section" do
    post rooms_boards_url, params: { room: { name: "Launch" }, user_ids: [ users(:david).id ] }

    streams = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
    assert_equal 1, streams.count
    assert_equal "prepend", streams.first["action"]
    assert_equal "board_rooms", streams.first["target"]
    assert_match "Launch", streams.first.to_html
  end

  test "create forbidden by non-admin when account restricts creation to admins" do
    accounts(:signal).settings.restrict_room_creation_to_administrators = true
    accounts(:signal).save!

    sign_in :jz
    post rooms_boards_url, params: { room: { name: "Launch" }, user_ids: [ users(:david).id, users(:kevin).id, users(:jason).id ] }
    assert_response :forbidden
  end

  test "create allowed for members when the account does not restrict creation" do
    sign_in :jz
    post rooms_boards_url, params: { room: { name: "Launch" }, user_ids: [ users(:jz).id ] }

    assert_redirected_to room_url(Room.last)
    assert_instance_of Rooms::Board, Room.last
  end

  test "update with membership revisions" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david), users(:jason), users(:jz) ])

    assert_difference -> { room.reload.users.count }, -1 do
      put rooms_board_url(room), params: {
        room: { name: "New Name" }, user_ids: room.users.without(users(:jason)).collect(&:id)
      }
    end

    assert_redirected_to room_url(room)
    assert_equal "New Name", room.reload.name
  end

  test "update replaces the board row and header" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david) ])

    put rooms_board_url(room), params: { room: { name: "New Name" }, user_ids: [ users(:david).id ] }
    assert_redirected_to room_url(room)

    streams = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
    assert_equal [ "replace", "replace" ], streams.map { |stream| stream["action"] }
    assert_equal [
      ActionView::RecordIdentifier.dom_id(room, :list),
      ActionView::RecordIdentifier.dom_id(room, :header)
    ], streams.map { |stream| stream["target"] }
  end

  test "a non-administrator creator can manage members of their own board" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:kevin) }, users: [ users(:kevin), users(:jz) ])

    sign_in :kevin
    put rooms_board_url(room), params: {
      room: { name: "New Name" }, user_ids: [ users(:kevin).id ]
    }

    assert_redirected_to room_url(room)
    assert_equal "New Name", room.reload.name
    assert_equal [ users(:kevin).id ], room.reload.user_ids
  end

  test "only admins or creators can update" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david), users(:jz) ])
    sign_in :jz

    assert_turbo_stream_broadcasts [ users(:jz), :rooms ], count: 0 do
      put rooms_board_url(room), params: { room: { name: "New Name" } }
    end

    assert_response :forbidden
    assert_equal "Launch", room.reload.name
  end

  test "remove yourself" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    assert_difference -> { users(:david).rooms.count }, -1 do
      put rooms_board_url(room, params: { room: { name: "Launch" }, user_ids: [ users(:jason).id ] })

      assert_redirected_to room_url(room)
      follow_redirect!
      assert_redirected_to root_url
    end
  end

  test "non-members cannot see the board page" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david) ])

    sign_in :jz
    get room_url(room)
    assert_redirected_to root_url
  end

  test "non-members cannot reach the board namespace" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david) ])

    sign_in :jz
    get rooms_board_url(room)
    assert_redirected_to root_url

    get edit_rooms_board_url(room)
    assert_redirected_to root_url
  end

  test "open and closed rooms cannot be converted to boards" do
    put rooms_board_url(rooms(:pets)), params: { room: { name: "Launch" }, user_ids: [ users(:david).id ] }
    assert_redirected_to root_url
    assert_equal "Rooms::Open", Room.find(rooms(:pets).id).type

    put rooms_board_url(rooms(:designers)), params: { room: { name: "Launch" }, user_ids: [ users(:david).id ] }
    assert_redirected_to root_url
    assert_equal "Rooms::Closed", Room.find(rooms(:designers).id).type
  end

  test "boards cannot be converted through the open or closed namespaces" do
    room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    put rooms_closed_url(room), params: { room: { name: "Watercooler" }, user_ids: [ users(:david).id, users(:jz).id ] }
    assert_redirected_to root_url

    put rooms_open_url(room), params: { room: { name: "Watercooler" } }
    assert_redirected_to root_url

    assert_equal "Rooms::Board", Room.find(room.id).type
    assert_equal [ users(:david).id, users(:jason).id ].sort, Room.find(room.id).user_ids.sort
  end

  test "a direct room can't be converted to a board and have its participants revised" do
    sign_in :kevin
    direct = rooms(:bender_and_kevin)

    put rooms_board_url(direct), params: {
      room: { name: "Launch" }, user_ids: [ users(:kevin).id, users(:jz).id ]
    }

    assert_redirected_to root_url
    assert_equal "Rooms::Direct", Room.find(direct.id).type
    assert_equal [ users(:bender).id, users(:kevin).id ].sort, Room.find(direct.id).user_ids.sort
  end
end
