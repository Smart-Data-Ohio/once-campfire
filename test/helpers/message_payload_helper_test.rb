require "test_helper"

class MessagePayloadHelperTest < ActionView::TestCase
  tests MessagePayloadHelper

  setup do
    @room = rooms(:designers)
    @message = messages(:first)
    Current.user = users(:david)
  end

  teardown do
    Current.user = nil
  end

  # reaction_payload reads the boosts association in memory, so a preloaded
  # message must not go back to the database for counts.

  test "reaction_payload counts distinct boosters per reaction without querying" do
    @message.boosts.destroy_all
    @message.boosts.create!(booster: users(:david), content: "👍")
    @message.boosts.create!(booster: users(:jason), content: "👍")
    @message.boosts.create!(booster: users(:jz), content: "🔥")

    message = Message.with_boosts.find(@message.id)
    payload = assert_no_queries { reaction_payload(message) }

    assert_equal 2, payload["👍"][:count]
    assert_equal 1, payload["🔥"][:count]
    assert_equal 0, payload["🎉"][:count]
    assert_equal "Thumbs up", payload["👍"][:title]
    assert_equal EmojiHelper::REACTIONS.keys, payload.keys
  end

  test "reaction_payload counts a booster once even with duplicate rows" do
    @message.boosts.destroy_all
    2.times { @message.boosts.create!(booster: users(:david), content: "👏") }

    assert_equal 1, reaction_payload(Message.with_boosts.find(@message.id))["👏"][:count]
  end

  test "reaction_payload marks the current user's own reaction active" do
    @message.boosts.destroy_all
    @message.boosts.create!(booster: users(:david), content: "❤️")
    @message.boosts.create!(booster: users(:jason), content: "🎉")

    payload = reaction_payload(Message.with_boosts.find(@message.id))

    assert payload["❤️"][:active]
    assert_not payload["🎉"][:active]
  end

  # A bot or a signed-out render has no Current.user. Comparing against nil must
  # not match a boost whose booster_id happens to be missing.
  test "reaction_payload reports nothing active when there is no current user" do
    @message.boosts.destroy_all
    @message.boosts.create!(booster: users(:david), content: "👍")
    Current.user = nil

    payload = reaction_payload(Message.with_boosts.find(@message.id))

    assert_equal 1, payload["👍"][:count]
    assert payload.values.none? { |reaction| reaction[:active] }
  end

  # caching_thread_payloads is opt-in and must leave nothing behind, so that an
  # action which mutates a thread after the block cannot serve a stale payload.

  test "caching_thread_payloads builds each thread payload once inside the block" do
    thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Payload cache")
    built = 0
    define_singleton_method(:build_thread_payload) { |*, **| built += 1; { id: thread.id } }

    caching_thread_payloads do
      3.times { thread_payload(thread) }
    end

    assert_equal 1, built
  end

  test "caching_thread_payloads keys on the payload options" do
    thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Payload cache options")
    built = 0
    define_singleton_method(:build_thread_payload) { |*, **| built += 1; {} }

    caching_thread_payloads do
      thread_payload(thread)
      thread_payload(thread)
      thread_payload(thread, include_work_history: true)
      thread_payload(thread, include_work_owner_options: true)
    end

    assert_equal 3, built
  end

  test "thread_payload does not cache outside the block" do
    thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Uncached payload")
    built = 0
    define_singleton_method(:build_thread_payload) { |*, **| built += 1; {} }

    2.times { thread_payload(thread) }

    assert_equal 2, built
  end

  test "caching_thread_payloads restores the previous cache, including after a raise" do
    thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Restored cache")
    define_singleton_method(:build_thread_payload) { |*, **| {} }

    assert_nil instance_variable_get(:@thread_payload_cache)

    caching_thread_payloads do
      outer = instance_variable_get(:@thread_payload_cache)
      thread_payload(thread)

      caching_thread_payloads { thread_payload(thread) }

      assert_same outer, instance_variable_get(:@thread_payload_cache)
      assert_equal 1, outer.size
    end

    assert_nil instance_variable_get(:@thread_payload_cache)

    assert_raises(RuntimeError) { caching_thread_payloads { raise "boom" } }
    assert_nil instance_variable_get(:@thread_payload_cache)
  end

  private
    def assert_no_queries
      queries = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
      end

      ActiveRecord::Base.connection_pool.clear_query_cache
      result = yield
      assert_empty queries, "expected no database queries"
      result
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
end
