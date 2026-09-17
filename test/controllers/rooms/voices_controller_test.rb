require "test_helper"

class Rooms::VoicesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david

    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each do |name, value|
      ENV[name] = value
    end
  end

  test "show redirects to get general show" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    get rooms_voice_url(room)
    assert_redirected_to room_url(room)
  end

  test "new" do
    get new_rooms_voice_url
    assert_response :success
  end

  test "create" do
    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
    assert_turbo_stream_broadcasts [ users(:kevin), :rooms ], count: 1 do
    assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 1 do
      post rooms_voices_url, params: { room: { name: "Lounge" }, user_ids: [ users(:david).id, users(:kevin).id, users(:jason).id ] }
    end
    end
    end

    new_room = Room.last
    assert_instance_of Rooms::Voice, new_room
    assert_equal new_room.memberships.count, 3
    assert_redirected_to room_url(Room.last)
  end

  test "create prepends the voice row into the voice section" do
    post rooms_voices_url, params: { room: { name: "Lounge" }, user_ids: [ users(:david).id ] }

    streams = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
    assert_equal 1, streams.count
    assert_equal "prepend", streams.first["action"]
    assert_equal "voice_rooms", streams.first["target"]
    assert_match "Lounge", streams.first.to_html
  end

  test "create forbidden by non-admin when account restricts creation to admins" do
    accounts(:signal).settings.restrict_room_creation_to_administrators = true
    accounts(:signal).save!

    sign_in :jz
    post rooms_voices_url, params: { room: { name: "Lounge" }, user_ids: [ users(:david).id, users(:kevin).id, users(:jason).id ] }
    assert_response :forbidden
  end

  test "update with an icon normalizes the shortcode" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    put rooms_voice_url(room), params: {
      room: { name: "Lounge", icon_name: ":fire:" }, user_ids: [ users(:david).id ]
    }

    assert_redirected_to room_url(room)
    assert_equal "fire", room.reload.icon_name
  end

  test "create with an unknown icon re-renders the new form" do
    assert_no_difference -> { Room.count } do
      post rooms_voices_url, params: { room: { name: "Iconic", icon_name: ":notanicon:" }, user_ids: [ users(:david).id ] }
    end

    assert_response :unprocessable_entity
    assert_match "Icon name is not a known icon", response.body
  end

  test "update with an unknown icon re-renders the edit form" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    put rooms_voice_url(room), params: {
      room: { name: "Lounge", icon_name: ":notanicon:" }, user_ids: [ users(:david).id ]
    }

    assert_response :unprocessable_entity
    assert_match "Icon name is not a known icon", response.body
    assert_nil room.reload.icon_name
  end

  test "update with membership revisions" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason), users(:jz) ])

    assert_difference -> { room.reload.users.count }, -1 do
      put rooms_voice_url(room), params: {
        room: { name: "New Name" }, user_ids: room.users.without(users(:jason)).collect(&:id)
      }
    end

    assert_redirected_to room_url(room)
    assert_equal "New Name", room.reload.name
  end

  test "removing a member tells them to drop the sidebar row and header stack" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    put rooms_voice_url(room), params: {
      room: { name: "Lounge" }, user_ids: [ users(:david).id ]
    }
    assert_redirected_to room_url(room)

    removed_streams = capture_turbo_stream_broadcasts([ users(:jason), :rooms ])
    assert_equal [ "remove", "remove" ], removed_streams.map { |stream| stream["action"] }
    # Header first: the sidebar row also drops on the reconnect reload, but
    # nothing else refreshes the header stack.
    assert_equal [
      ActionView::RecordIdentifier.dom_id(room, :header_voice_participants),
      ActionView::RecordIdentifier.dom_id(room, :list)
    ], removed_streams.map { |stream| stream["target"] }

    remaining_streams = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
    assert_equal [ "replace", "replace" ], remaining_streams.map { |stream| stream["action"] }
    assert_equal [
      ActionView::RecordIdentifier.dom_id(room, :list),
      ActionView::RecordIdentifier.dom_id(room, :header)
    ], remaining_streams.map { |stream| stream["target"] }
  end

  test "a non-administrator creator can manage members of their own voice room" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:kevin) }, users: [ users(:kevin), users(:jz) ])

    sign_in :kevin
    put rooms_voice_url(room), params: {
      room: { name: "New Name" }, user_ids: [ users(:kevin).id ]
    }

    assert_redirected_to room_url(room)
    assert_equal "New Name", room.reload.name
    assert_equal [ users(:kevin).id ], room.reload.user_ids
  end

  test "only admins or creators can update" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jz) ])
    sign_in :jz

    assert_turbo_stream_broadcasts [ users(:jz), :rooms ], count: 0 do
      put rooms_voice_url(room), params: { room: { name: "New Name" } }
    end

    assert_response :forbidden
    assert_equal "Lounge", room.reload.name
  end

  test "remove yourself" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    assert_difference -> { users(:david).rooms.count }, -1 do
      put rooms_voice_url(room, params: { room: { name: "Lounge" }, user_ids: [ users(:jason).id ] })

      assert_redirected_to room_url(room)
      follow_redirect!
      assert_redirected_to root_url
    end
  end

  test "non-members cannot see the room page or its messages" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])
    room.messages.create!(creator: users(:david), body: "Secret voice chat")

    sign_in :jz
    get room_url(room)
    assert_redirected_to root_url

    assert_raises(ActiveRecord::RecordNotFound) do
      get room_messages_url(room)
    end
  end

  test "non-members cannot reach the voice namespace" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    sign_in :jz
    get rooms_voice_url(room)
    assert_redirected_to root_url

    get edit_rooms_voice_url(room)
    assert_redirected_to root_url
  end

  test "open and closed rooms cannot be converted to voice" do
    put rooms_voice_url(rooms(:pets)), params: { room: { name: "Lounge" }, user_ids: [ users(:david).id ] }
    assert_redirected_to root_url
    assert_equal "Rooms::Open", Room.find(rooms(:pets).id).type

    put rooms_voice_url(rooms(:designers)), params: { room: { name: "Lounge" }, user_ids: [ users(:david).id ] }
    assert_redirected_to root_url
    assert_equal "Rooms::Closed", Room.find(rooms(:designers).id).type
  end

  test "voice rooms cannot be converted through the open or closed namespaces" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    put rooms_closed_url(room), params: { room: { name: "Watercooler" }, user_ids: [ users(:david).id, users(:jz).id ] }
    assert_redirected_to root_url

    put rooms_open_url(room), params: { room: { name: "Watercooler" } }
    assert_redirected_to root_url

    assert_equal "Rooms::Voice", Room.find(room.id).type
    assert_equal [ users(:david).id, users(:jason).id ].sort, Room.find(room.id).user_ids.sort
  end

  test "a direct room can't be converted to voice and have its participants revised" do
    sign_in :kevin
    direct = rooms(:bender_and_kevin)

    put rooms_voice_url(direct), params: {
      room: { name: "Lounge" }, user_ids: [ users(:kevin).id, users(:jz).id ]
    }

    assert_redirected_to root_url
    assert_equal "Rooms::Direct", Room.find(direct.id).type
    assert_equal [ users(:bender).id, users(:kevin).id ].sort, Room.find(direct.id).user_ids.sort
  end
end
