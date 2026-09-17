require "test_helper"

class Github::RepositorySubscriptionTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
  end

  test "new subscriptions default to the standard event selection" do
    subscription = Github::RepositorySubscription.create!(room: @room, owner: "rails", repo: "rails", created_by: users(:david))

    assert_equal %w[ opened merged review_requested checks_failed ], subscription.events
  end

  test "event keys are validated against the known set" do
    subscription = Github::RepositorySubscription.new(room: @room, owner: "rails", repo: "rails", events: %w[ opened push ])

    assert_not subscription.valid?
    assert_includes subscription.errors[:events], "must be a subset of #{Github::RepositorySubscription::EVENT_KEYS.to_sentence}"

    subscription.events = %w[ opened closed ]
    assert subscription.valid?
  end

  test "owner and repo are stripped and downcased" do
    subscription = Github::RepositorySubscription.create!(
      room: @room, owner: "  Rails ", repo: " Rails ", created_by: users(:david))

    assert_equal "rails", subscription.owner
    assert_equal "rails", subscription.repo
  end

  test "owner and repo follow pull request url character rules" do
    valid = Github::RepositorySubscription.new(room: @room, owner: "my-org", repo: "my.repo_v2", events: [])
    assert valid.valid?, valid.errors.full_messages.to_sentence

    %w[ . .. ].each do |name|
      invalid = Github::RepositorySubscription.new(room: @room, owner: name, repo: "rails", events: [])
      assert_not invalid.valid?, "expected #{name.inspect} owner to be rejected"
      assert invalid.errors[:owner].any?
    end

    invalid = Github::RepositorySubscription.new(room: @room, owner: "rails", repo: "has space", events: [])
    assert_not invalid.valid?
    assert invalid.errors[:repo].any?

    invalid = Github::RepositorySubscription.new(room: @room, owner: "rails/hack", repo: "rails", events: [])
    assert_not invalid.valid?
  end

  test "one subscription per room and repository, case-insensitively" do
    Github::RepositorySubscription.create!(room: @room, owner: "rails", repo: "rails", created_by: users(:david))

    duplicate = Github::RepositorySubscription.new(room: @room, owner: "Rails", repo: "RAILS", events: [])
    assert_not duplicate.valid?
    assert duplicate.errors[:owner].any?

    other_room = Github::RepositorySubscription.new(room: rooms(:watercooler), owner: "rails", repo: "rails", events: [])
    assert other_room.valid?
  end

  test "clearing every event on an existing subscription is rejected" do
    subscription = Github::RepositorySubscription.create!(room: @room, owner: "rails", repo: "rails", created_by: users(:david))

    assert_not subscription.update(events: [])
    assert_equal [ "must include at least one event" ], subscription.errors[:events]
    assert_equal Github::RepositorySubscription::DEFAULT_EVENTS, subscription.reload.events
  end

  test "direct rooms cannot be subscribed" do
    subscription = Github::RepositorySubscription.new(room: rooms(:david_and_jason), owner: "rails", repo: "rails", events: [])

    assert_not subscription.valid?
    assert_equal [ "must not be a direct room" ], subscription.errors[:room]
  end

  test "subscribing adds the github bot to the room" do
    assert_difference -> { User.active_bots.where(name: "GitHub").count }, 1 do
      Github::RepositorySubscription.create!(room: @room, owner: "rails", repo: "rails", created_by: users(:david))
    end

    bot = User.active_bots.find_by!(name: "GitHub")
    assert bot.bot_token.present?
    assert_nil bot.agent
    assert @room.memberships.exists?(user: bot)
  end

  test "the github bot joins only subscribed rooms" do
    Github::RepositorySubscription.create!(room: @room, owner: "rails", repo: "rails", created_by: users(:david))

    bot = User.active_bots.find_by!(name: "GitHub")
    assert_equal [ @room.id ], bot.rooms.ids
  end

  test "destroying the last subscription removes the bot from the room" do
    first = Github::RepositorySubscription.create!(room: @room, owner: "rails", repo: "rails", created_by: users(:david))
    second = Github::RepositorySubscription.create!(room: @room, owner: "rails", repo: "propshaft", created_by: users(:david))
    bot = User.active_bots.find_by!(name: "GitHub")

    first.destroy!
    assert @room.memberships.exists?(user: bot)

    second.destroy!
    assert_not @room.memberships.exists?(user: bot)
  end
end
