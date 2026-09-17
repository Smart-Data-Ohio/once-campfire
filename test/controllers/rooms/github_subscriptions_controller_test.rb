require "test_helper"

class Rooms::GithubSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
  end

  test "administrator can subscribe a room with default events" do
    assert_difference -> { @room.github_repository_subscriptions.count }, 1 do
      post room_github_subscriptions_url(@room), params: {
        github_repository_subscription: { full_name: "Rails/Rails" }
      }
    end

    assert_redirected_to edit_rooms_closed_url(@room)

    subscription = @room.github_repository_subscriptions.last
    assert_equal "rails", subscription.owner
    assert_equal "rails", subscription.repo
    assert_equal Github::RepositorySubscription::DEFAULT_EVENTS, subscription.events
    assert_equal users(:david), subscription.created_by
    assert @room.memberships.exists?(user: User.active_bots.find_by!(name: "GitHub"))
  end

  test "administrator can subscribe with an explicit event selection" do
    post room_github_subscriptions_url(@room), params: {
      github_repository_subscription: { full_name: "rails/rails", events: [ "opened", "merged", "" ] }
    }

    assert_redirected_to edit_rooms_closed_url(@room)
    assert_equal %w[ opened merged ], @room.github_repository_subscriptions.last.events
  end

  test "subscribing an open room returns to its edit page" do
    post room_github_subscriptions_url(rooms(:pets)), params: {
      github_repository_subscription: { full_name: "rails/rails" }
    }

    assert_redirected_to edit_rooms_open_url(rooms(:pets))
  end

  test "room creator can subscribe without being an administrator" do
    room = Rooms::Closed.create!(name: "JZ Room", creator: users(:jz))
    room.memberships.grant_to(users(:jz))
    sign_in :jz

    post room_github_subscriptions_url(room), params: {
      github_repository_subscription: { full_name: "rails/rails" }
    }

    assert_redirected_to edit_rooms_closed_url(room)
    assert room.github_repository_subscriptions.exists?(owner: "rails", repo: "rails")
  end

  test "duplicate and malformed subscriptions redirect with an alert" do
    @room.github_repository_subscriptions.create!(owner: "rails", repo: "rails", created_by: users(:david))

    assert_no_difference -> { Github::RepositorySubscription.count } do
      post room_github_subscriptions_url(@room), params: {
        github_repository_subscription: { full_name: "rails/rails" }
      }
    end
    assert_redirected_to edit_rooms_closed_url(@room)
    assert_equal "Could not subscribe: Owner has already been taken.", flash[:alert]

    assert_no_difference -> { Github::RepositorySubscription.count } do
      post room_github_subscriptions_url(@room), params: {
        github_repository_subscription: { full_name: "not-a-repo" }
      }
    end
    assert_redirected_to edit_rooms_closed_url(@room)
    assert flash[:alert].start_with?("Could not subscribe:")
  end

  test "administrator can change events and remove a subscription" do
    subscription = @room.github_repository_subscriptions.create!(
      owner: "rails", repo: "rails", created_by: users(:david))
    bot = User.active_bots.find_by!(name: "GitHub")

    patch room_github_subscription_url(@room, subscription), params: {
      github_repository_subscription: { events: [ "merged", "" ] }
    }

    assert_redirected_to edit_rooms_closed_url(@room)
    assert_equal %w[ merged ], subscription.reload.events

    delete room_github_subscription_url(@room, subscription)

    assert_redirected_to edit_rooms_closed_url(@room)
    assert_not Github::RepositorySubscription.exists?(subscription.id)
    assert_not @room.memberships.exists?(user: bot)
  end

  test "removing one of several subscriptions keeps the bot in the room" do
    first = @room.github_repository_subscriptions.create!(owner: "rails", repo: "rails", created_by: users(:david))
    @room.github_repository_subscriptions.create!(owner: "rails", repo: "propshaft", created_by: users(:david))
    bot = User.active_bots.find_by!(name: "GitHub")

    delete room_github_subscription_url(@room, first)

    assert_redirected_to edit_rooms_closed_url(@room)
    assert @room.memberships.exists?(user: bot)
  end

  test "plain members get forbidden" do
    sign_in :jz
    subscription = @room.github_repository_subscriptions.create!(
      owner: "rails", repo: "rails", created_by: users(:david))

    post room_github_subscriptions_url(@room), params: {
      github_repository_subscription: { full_name: "rails/propshaft" }
    }
    assert_response :forbidden

    patch room_github_subscription_url(@room, subscription), params: {
      github_repository_subscription: { events: [ "merged" ] }
    }
    assert_response :forbidden

    delete room_github_subscription_url(@room, subscription)
    assert_response :forbidden

    assert Github::RepositorySubscription.exists?(subscription.id)
  end

  test "non-members get not found" do
    sign_in :kevin # not a member of the watercooler

    # RoomScoped raises RecordNotFound, which renders 404 outside tests.
    assert_raises(ActiveRecord::RecordNotFound) do
      post room_github_subscriptions_url(rooms(:watercooler)), params: {
        github_repository_subscription: { full_name: "rails/rails" }
      }
    end
  end

  test "direct rooms get not found" do
    post room_github_subscriptions_url(rooms(:david_and_jason)), params: {
      github_repository_subscription: { full_name: "rails/rails" }
    }
    assert_response :not_found
  end

  test "github section renders for administrators but not plain members" do
    get edit_rooms_closed_url(@room)
    assert_response :success
    assert_select "#github-subscriptions"

    get edit_rooms_open_url(rooms(:pets))
    assert_response :success
    assert_select "#github-subscriptions"

    sign_in :jz
    get edit_rooms_closed_url(@room)
    assert_response :success
    assert_select "#github-subscriptions", count: 0
  end
end
