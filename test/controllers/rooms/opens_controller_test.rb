require "test_helper"

class Rooms::OpensControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show redirects to get general show" do
    get rooms_open_url(users(:david).rooms.opens.last)
    assert_redirected_to room_url(users(:david).rooms.opens.last)
  end

  test "new" do
    get new_rooms_open_url
    assert_response :success
  end

  test "create" do
    assert_turbo_stream_broadcasts :rooms, count: 1 do
      post rooms_opens_url, params: { room: { name: "My New Room" } }
    end

    assert_equal Room.last.memberships.count, User.count
    assert_redirected_to room_url(Room.last)
  end

  test "create forbidden by non-admin when account restricts creation to admins" do
    accounts(:signal).settings.restrict_room_creation_to_administrators = true
    accounts(:signal).save!

    sign_in :jz
    post rooms_opens_url, params: { room: { name: "My New Room" } }
    assert_response :forbidden
  end

  test "only admins or creators can update" do
    sign_in :jz

    assert_turbo_stream_broadcasts :rooms, count: 0 do
      put rooms_open_url(rooms(:hq)), params: { room: { name: "New Name" } }
    end

    assert_response :forbidden
    assert rooms(:hq).reload.name, "HQ"
  end

  test "update" do
    # Sidebar row plus room header.
    assert_turbo_stream_broadcasts :rooms, count: 2 do
      put rooms_open_url(rooms(:pets)), params: { room: { name: "New Name" } }
    end

    assert_redirected_to room_url(rooms(:pets))
    assert rooms(:pets).reload.name, "New Name"
  end

  test "update with an icon normalizes the shortcode" do
    put rooms_open_url(rooms(:pets)), params: { room: { name: "All Pets", icon_name: " :OpenAI: " } }

    assert_redirected_to room_url(rooms(:pets))
    assert_equal "openai", rooms(:pets).reload.icon_name
  end

  test "update clears the icon with a blank shortcode" do
    rooms(:pets).update!(icon_name: "openai")

    put rooms_open_url(rooms(:pets)), params: { room: { name: "All Pets", icon_name: "" } }

    assert_redirected_to room_url(rooms(:pets))
    assert_nil rooms(:pets).reload.icon_name
  end

  test "a plain member cannot set an icon" do
    sign_in :jz

    put rooms_open_url(rooms(:hq)), params: { room: { name: "HQ", icon_name: "openai" } }

    assert_response :forbidden
    assert_nil rooms(:hq).reload.icon_name
  end

  test "update ignores unpermitted keys" do
    put rooms_open_url(rooms(:pets)), params: {
      room: { name: "All Pets", icon_name: "openai", type: "Rooms::Direct", creator_id: users(:jz).id }
    }

    room = rooms(:pets).reload
    assert_equal "openai", room.icon_name
    assert_equal "Rooms::Open", room.type
    assert_equal users(:david).id, room.creator_id
  end

  test "update a closed room to be open" do
    put rooms_open_url(rooms(:designers)), params: { room: { name: "Doesn't matter" } }
    assert_equal rooms(:designers).memberships.count, User.count
  end

  test "a direct room can't be promoted to open by its creator" do
    sign_in :kevin
    direct = rooms(:bender_and_kevin)

    put rooms_open_url(direct), params: { room: { name: "Watercooler" } }

    assert_equal "Rooms::Direct", Room.find(direct.id).type
    assert_equal [ users(:bender).id, users(:kevin).id ].sort, Room.find(direct.id).user_ids.sort
  end

  test "a direct room can't be promoted to open by an administrator either" do
    direct = rooms(:david_and_kevin)

    put rooms_open_url(direct), params: { room: { name: "Watercooler" } }

    assert_equal "Rooms::Direct", Room.find(direct.id).type
    assert_equal [ users(:david).id, users(:kevin).id ].sort, Room.find(direct.id).user_ids.sort
  end
end
