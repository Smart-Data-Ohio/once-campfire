require "test_helper"

class Rooms::StagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show redirects to get general show" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david) ])

    get rooms_stage_url(room)
    assert_redirected_to room_url(room)
  end

  test "new" do
    get new_rooms_stage_url
    assert_response :success
  end

  test "create makes the creator host and the rest listeners" do
    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
    assert_turbo_stream_broadcasts [ users(:kevin), :rooms ], count: 1 do
    assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 1 do
      post rooms_stages_url, params: { room: { name: "Town Hall" }, user_ids: [ users(:david).id, users(:kevin).id, users(:jason).id ] }
    end
    end
    end

    new_room = Room.last
    assert_instance_of Rooms::Stage, new_room
    assert_equal 3, new_room.memberships.count
    assert_equal "host", new_room.memberships.find_by!(user: users(:david)).stage_role
    assert_equal "listener", new_room.memberships.find_by!(user: users(:kevin)).stage_role
    assert_equal "listener", new_room.memberships.find_by!(user: users(:jason)).stage_role
    assert_redirected_to room_url(Room.last)
  end

  test "create prepends the stage row into the voice section" do
    post rooms_stages_url, params: { room: { name: "Town Hall" }, user_ids: [ users(:david).id ] }

    streams = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
    assert_equal 1, streams.count
    assert_equal "prepend", streams.first["action"]
    assert_equal "voice_rooms", streams.first["target"]
    assert_match "Town Hall", streams.first.to_html
    assert_match "stage-room", streams.first.to_html
  end

  test "create forbidden by non-admin when account restricts creation to admins" do
    accounts(:signal).settings.restrict_room_creation_to_administrators = true
    accounts(:signal).save!

    sign_in :jz
    post rooms_stages_url, params: { room: { name: "Town Hall" }, user_ids: [ users(:david).id, users(:kevin).id, users(:jason).id ] }
    assert_response :forbidden
  end

  test "update with membership revisions makes new members listeners" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason), users(:jz) ])

    assert_difference -> { room.reload.users.count }, -1 do
      put rooms_stage_url(room), params: {
        room: { name: "New Name" }, user_ids: room.users.without(users(:jason)).collect(&:id)
      }
    end

    assert_redirected_to room_url(room)
    assert_equal "New Name", room.reload.name

    put rooms_stage_url(room), params: {
      room: { name: "New Name" }, user_ids: room.users.collect(&:id) + [ users(:kevin).id ]
    }
    assert_equal "listener", room.reload.memberships.find_by!(user: users(:kevin)).stage_role
    assert_equal "host", room.memberships.find_by!(user: users(:david)).stage_role
  end

  test "removing a member tells them to drop the sidebar row and header stack" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    put rooms_stage_url(room), params: {
      room: { name: "Town Hall" }, user_ids: [ users(:david).id ]
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

  test "a non-administrator creator can manage members of their own stage room" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:kevin) }, users: [ users(:kevin), users(:jz) ])

    sign_in :kevin
    put rooms_stage_url(room), params: {
      room: { name: "New Name" }, user_ids: [ users(:kevin).id ]
    }

    assert_redirected_to room_url(room)
    assert_equal "New Name", room.reload.name
    assert_equal [ users(:kevin).id ], room.reload.user_ids
  end

  test "only admins or creators can update" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jz) ])
    sign_in :jz

    assert_turbo_stream_broadcasts [ users(:jz), :rooms ], count: 0 do
      put rooms_stage_url(room), params: { room: { name: "New Name" } }
    end

    assert_response :forbidden
    assert_equal "Town Hall", room.reload.name
  end

  test "the sole host cannot remove themselves while others remain" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    assert_no_difference -> { users(:david).rooms.count } do
      put rooms_stage_url(room, params: { room: { name: "New Name" }, user_ids: [ users(:jason).id ] })

      assert_response :unprocessable_entity
      assert_match "Promote another host before removing David", response.body
    end

    assert_equal "Town Hall", room.reload.name
    assert_equal [ users(:david).id, users(:jason).id ].sort, room.reload.user_ids.sort
  end

  test "create with an unknown icon re-renders the new form" do
    assert_no_difference -> { Room.count } do
      post rooms_stages_url, params: { room: { name: "Iconic", icon_name: ":notanicon:" }, user_ids: [ users(:david).id ] }
    end

    assert_response :unprocessable_entity
    assert_match "Icon name is not a known icon", response.body
  end

  test "update with an unknown icon re-renders the edit form without revising members" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    put rooms_stage_url(room), params: {
      room: { name: "New Name", icon_name: ":notanicon:" }, user_ids: [ users(:david).id ]
    }

    assert_response :unprocessable_entity
    assert_match "Icon name is not a known icon", response.body
    assert_nil room.reload.icon_name
    assert_equal "Town Hall", room.name
    assert_equal [ users(:david).id, users(:jason).id ].sort, room.user_ids.sort
  end

  test "update with an icon normalizes the shortcode" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david) ])

    put rooms_stage_url(room), params: {
      room: { name: "Town Hall", icon_name: ":fire:" }, user_ids: [ users(:david).id ]
    }

    assert_redirected_to room_url(room)
    assert_equal "fire", room.reload.icon_name
  end

  test "update clears the icon with a blank shortcode" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david) ])
    room.update!(icon_name: "openai")

    put rooms_stage_url(room), params: {
      room: { name: "Town Hall", icon_name: "" }, user_ids: [ users(:david).id ]
    }

    assert_redirected_to room_url(room)
    assert_nil room.reload.icon_name
  end

  test "updating the icon replaces sidebar rows and headers for members only" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    put rooms_stage_url(room), params: {
      room: { name: room.name, icon_name: ":openai:" }, user_ids: room.user_ids
    }

    assert_redirected_to room_url(room)
    assert_equal "openai", room.reload.icon_name

    icon_src = Icons.brand_image_urls.fetch("openai")
    room.users.each do |member|
      assert_rendered_turbo_stream_broadcast member, :rooms, action: "replace", target: [ room, :list ] do
        assert_select ".stage-room .sidebar-item__icon--custom img.icon-avatar[src='#{icon_src}']"
      end
      assert_rendered_turbo_stream_broadcast member, :rooms, action: "replace", target: [ room, :header ] do
        assert_select "img.icon-avatar[src='#{icon_src}']"
      end
    end

    assert_empty capture_turbo_stream_broadcasts([ users(:kevin), :rooms ])
  end

  test "a host removes themselves once another host exists" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    room.memberships.find_by!(user: users(:jason)).change_stage_role!("host")

    assert_difference -> { users(:david).rooms.count }, -1 do
      put rooms_stage_url(room, params: { room: { name: "Town Hall" }, user_ids: [ users(:jason).id ] })

      assert_redirected_to room_url(room)
      follow_redirect!
      assert_redirected_to root_url
    end
  end

  test "the sole-host check and revision run in one locked transaction" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    events = []

    lock_method = Room.instance_method(:lock!)
    Room.define_method(:lock!) do |*arguments|
      events << :lock
      lock_method.bind_call(self, *arguments)
    end

    insert_method = Membership.method(:insert_all)
    Membership.define_singleton_method(:insert_all) do |*arguments, **keywords|
      events << (ActiveRecord::Base.connection.transaction_open? ? :insert_in_transaction : :insert_outside_transaction)
      insert_method.call(*arguments, **keywords)
    end

    begin
      put rooms_stage_url(room), params: {
        room: { name: "Town Hall" }, user_ids: [ users(:david).id, users(:jason).id, users(:kevin).id ]
      }
    ensure
      Room.define_method(:lock!, lock_method)
      Membership.define_singleton_method(:insert_all, insert_method)
    end

    assert_redirected_to room_url(room)
    assert_equal [ :lock, :insert_in_transaction ], events
  end

  test "removing everyone including the last host empties the room" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    put rooms_stage_url(room, params: { room: { name: "Town Hall" }, user_ids: [] })

    assert_redirected_to room_url(room)
    assert_empty room.reload.users
  end

  test "non-members cannot see the room page or its messages" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david) ])
    room.messages.create!(creator: users(:david), body: "Secret stage chat")

    sign_in :jz
    get room_url(room)
    assert_redirected_to root_url

    assert_raises(ActiveRecord::RecordNotFound) do
      get room_messages_url(room)
    end
  end

  test "non-members cannot reach the stage namespace" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david) ])

    sign_in :jz
    get rooms_stage_url(room)
    assert_redirected_to root_url

    get edit_rooms_stage_url(room)
    assert_redirected_to root_url
  end

  test "open, closed, and voice rooms cannot be converted to stage" do
    put rooms_stage_url(rooms(:pets)), params: { room: { name: "Town Hall" }, user_ids: [ users(:david).id ] }
    assert_redirected_to root_url
    assert_equal "Rooms::Open", Room.find(rooms(:pets).id).type

    put rooms_stage_url(rooms(:designers)), params: { room: { name: "Town Hall" }, user_ids: [ users(:david).id ] }
    assert_redirected_to root_url
    assert_equal "Rooms::Closed", Room.find(rooms(:designers).id).type

    voice = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    put rooms_stage_url(voice), params: { room: { name: "Town Hall" }, user_ids: [ users(:david).id ] }
    assert_redirected_to root_url
    assert_equal "Rooms::Voice", Room.find(voice.id).type
    assert_equal [ users(:david).id, users(:jason).id ].sort, Room.find(voice.id).user_ids.sort
  end

  test "stage rooms cannot be converted through the open, closed, or voice namespaces" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    put rooms_closed_url(room), params: { room: { name: "Watercooler" }, user_ids: [ users(:david).id, users(:jz).id ] }
    assert_redirected_to root_url

    put rooms_open_url(room), params: { room: { name: "Watercooler" } }
    assert_redirected_to root_url

    put rooms_voice_url(room), params: { room: { name: "Lounge" }, user_ids: [ users(:david).id ] }
    assert_redirected_to root_url

    assert_equal "Rooms::Stage", Room.find(room.id).type
    assert_equal [ users(:david).id, users(:jason).id ].sort, Room.find(room.id).user_ids.sort
  end

  test "a direct room can't be converted to stage and have its participants revised" do
    sign_in :kevin
    direct = rooms(:bender_and_kevin)

    put rooms_stage_url(direct), params: {
      room: { name: "Town Hall" }, user_ids: [ users(:kevin).id, users(:jz).id ]
    }

    assert_redirected_to root_url
    assert_equal "Rooms::Direct", Room.find(direct.id).type
    assert_equal [ users(:bender).id, users(:kevin).id ].sort, Room.find(direct.id).user_ids.sort
  end
end
