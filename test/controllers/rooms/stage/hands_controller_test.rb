require "test_helper"

class Rooms::Stage::HandsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    @listener = @room.memberships.find_by!(user: users(:jason))
  end

  test "a listener raises their hand and every viewer gets their own roster" do
    sign_in :jason

    assert_turbo_stream_broadcasts [ @room, :messages ], count: 0 do
      assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
        assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 1 do
          assert_turbo_stream_broadcasts [ users(:kevin), :rooms ], count: 1 do
            post room_stage_hand_url(@room)
          end
        end
      end
    end

    assert_redirected_to room_url(@room)
    assert_predicate @listener.reload, :hand_raised?

    roster_target = ActionView::RecordIdentifier.dom_id(@room, :stage_roster)

    host_streams = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
    assert_equal "replace", host_streams.first["action"]
    assert_equal roster_target, host_streams.first["target"]
    assert_match "Hand raised", host_streams.first.to_html
    assert_match "Invite to speak", host_streams.first.to_html

    listener_streams = capture_turbo_stream_broadcasts([ users(:kevin), :rooms ])
    assert_equal roster_target, listener_streams.first["target"]
    assert_match "Hand raised", listener_streams.first.to_html
    assert_no_match "Invite to speak", listener_streams.first.to_html
    assert_no_match "Make host", listener_streams.first.to_html
  end

  test "a turbo-stream raise swaps the actor's own controls without navigating" do
    sign_in :jason

    post room_stage_hand_url(@room), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal Mime[:turbo_stream], response.media_type
    assert_match ActionView::RecordIdentifier.dom_id(@room, :stage_controls), response.body
    assert_match "Lower hand", response.body
  end

  test "speakers and hosts cannot raise a hand" do
    @listener.change_stage_role!("speaker")

    sign_in :jason
    post room_stage_hand_url(@room)
    assert_response :unprocessable_entity
    assert_equal "Only listeners can raise a hand", response.body

    sign_in :david
    post room_stage_hand_url(@room)
    assert_response :unprocessable_entity
    assert_equal "Only listeners can raise a hand", response.body
  end

  test "a listener lowers their own hand" do
    @listener.raise_hand!
    sign_in :jason

    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
      assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 1 do
        assert_turbo_stream_broadcasts [ users(:kevin), :rooms ], count: 1 do
          delete room_stage_hand_url(@room)
        end
      end
    end

    assert_redirected_to room_url(@room)
    assert_not_predicate @listener.reload, :hand_raised?
  end

  test "lowering a hand that was never raised succeeds" do
    sign_in :jason

    delete room_stage_hand_url(@room)

    assert_redirected_to room_url(@room)
    assert_not_predicate @listener.reload, :hand_raised?
  end

  test "a host lowers another member's hand without promoting them" do
    @listener.raise_hand!
    sign_in :david

    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
      assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 1 do
        assert_turbo_stream_broadcasts [ users(:kevin), :rooms ], count: 1 do
          delete room_stage_hand_url(@room), params: { membership_id: @listener.id }
        end
      end
    end

    assert_redirected_to room_url(@room)
    assert_not_predicate @listener.reload, :hand_raised?
    assert_equal "listener", @listener.stage_role
  end

  test "an administrator member lowers another member's hand" do
    users(:kevin).update!(role: :administrator)
    @listener.raise_hand!
    sign_in :kevin

    delete room_stage_hand_url(@room), params: { membership_id: @listener.id }

    assert_redirected_to room_url(@room)
    assert_not_predicate @listener.reload, :hand_raised?
  end

  test "a listener cannot lower another member's hand" do
    @listener.raise_hand!
    sign_in :kevin

    delete room_stage_hand_url(@room), params: { membership_id: @listener.id }

    assert_response :forbidden
    assert_predicate @listener.reload, :hand_raised?
  end

  test "lowering a non-member's hand is not found" do
    sign_in :david

    delete room_stage_hand_url(@room), params: { membership_id: 0 }

    assert_response :not_found
  end

  test "non-members get not found" do
    sign_in :jz

    post room_stage_hand_url(@room)
    assert_response :not_found

    delete room_stage_hand_url(@room)
    assert_response :not_found
  end

  test "an administrator who is not a member gets not found" do
    users(:jz).update!(role: :administrator)
    sign_in :jz

    post room_stage_hand_url(@room)
    assert_response :not_found

    delete room_stage_hand_url(@room)
    assert_response :not_found
  end

  test "hands do not exist outside stage rooms" do
    voice = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    sign_in :jason

    post room_stage_hand_url(voice)
    assert_response :not_found

    delete room_stage_hand_url(voice)
    assert_response :not_found
  end
end
