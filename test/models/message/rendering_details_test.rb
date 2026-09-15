require "test_helper"

# with_rendering_details exists to make rendering a page of messages cost a
# fixed number of queries. These tests fail if a preload is ever silently
# dropped - for instance by chaining a scope whose result is discarded, or by
# applying a scope to an already-preloaded association.
class Message::RenderingDetailsTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
    @people = [ users(:david), users(:jason), users(:jz) ]
    @people.each { |user| @room.memberships.find_or_create_by!(user:) }
    Current.user = users(:david)
  end

  teardown do
    Current.user = nil
  end

  test "with_rendering_details costs the same number of queries regardless of page size" do
    create_messages(3)
    small = count_queries { touch_rendered_details Message.with_rendering_details.where(room: @room).to_a }

    create_messages(15, offset: 3)
    large = count_queries { touch_rendered_details Message.with_rendering_details.where(room: @room).to_a }

    assert_equal small, large,
      "with_rendering_details should be O(1) in queries, got #{small} for a small page and #{large} for a larger one"
  end

  test "with_rendering_details loads every association the message partials read" do
    messages = create_messages(3)
    reply = @room.messages.create!(creator: users(:jason), client_message_id: "render-reply",
      reply_to_message: messages.first, body: "a reply")
    reply.boosts.create!(booster: users(:jz), content: "👍")

    loaded = Message.with_rendering_details.where(room: @room).to_a
    subject = loaded.find { |message| message.id == reply.id }

    assert_predicate subject.association(:boosts), :loaded?
    assert_predicate subject.association(:room), :loaded?
    assert_predicate subject.association(:creator), :loaded?
    assert_predicate subject.association(:rich_text_body), :loaded?
    assert_predicate subject.association(:reply_to_message), :loaded?
    assert_predicate subject.reply_to_message.association(:rich_text_body), :loaded?
    assert_predicate subject.reply_to_message.creator.association(:avatar_attachment), :loaded?
    assert_predicate subject.boosts.first.association(:booster), :loaded?
  end

  test "ordered_boosts reads the preloaded rows rather than issuing a query" do
    message = create_messages(1).first
    3.times { |i| message.boosts.create!(booster: @people[i], content: "👍") }

    subject = Message.with_rendering_details.find(message.id)

    assert_equal 0, count_queries { subject.ordered_boosts }
  end

  test "ordered_boosts sorts oldest first and breaks ties by id" do
    message = create_messages(1).first
    base = 1.hour.ago.change(usec: 0)

    # Ids are assigned explicitly because this app generates random ids, and the
    # tie-break has to be checked against a known order rather than a lucky one.
    # The rows are inserted in the opposite order to the one expected back, so a
    # sort that fell through to insertion order would fail here.
    later = message.boosts.create!(id: 3, booster: @people[0], content: "🔥", created_at: base + 1.minute)
    tie_b = message.boosts.create!(id: 2, booster: @people[1], content: "👏", created_at: base)
    tie_a = message.boosts.create!(id: 1, booster: @people[2], content: "👍", created_at: base)

    assert_equal [ tie_a.id, tie_b.id, later.id ],
      Message.with_rendering_details.find(message.id).ordered_boosts.map(&:id)
  end

  test "ordered_boosts matches the ordered scope it replaced" do
    message = create_messages(1).first
    base = 2.hours.ago.change(usec: 0)
    [ 2, 0, 1, 0 ].each_with_index do |offset, i|
      message.boosts.create!(booster: @people[i % @people.size], content: "👋",
        created_at: base + offset.minutes)
    end

    assert_equal message.boosts.ordered.pluck(:id),
      Message.with_rendering_details.find(message.id).ordered_boosts.map(&:id)
  end

  test "ordered_boosts is empty for a message with no boosts" do
    assert_equal [], Message.with_rendering_details.find(create_messages(1).first.id).ordered_boosts
  end

  test "preload_rendering_details loads the same associations onto an already-selected page" do
    messages = create_messages(3)
    messages.first.boosts.create!(booster: users(:jz), content: "🔥")

    records = Message.where(room: @room).to_a
    assert_not records.first.association(:boosts).loaded?

    assert_same records, Message.preload_rendering_details(records)
    assert records.all? { |record| record.association(:boosts).loaded? }
    assert records.all? { |record| record.association(:creator).loaded? }
    assert_equal 0, count_queries { touch_rendered_details(records) }
  end

  test "preload_rendering_details is a no-op on an empty page" do
    assert_equal [], Message.preload_rendering_details([])
    assert_equal 0, count_queries { Message.preload_rendering_details([]) }
  end

  test "rendering_associations mirrors the scope rather than a hand-written list" do
    relation = Message.with_rendering_details

    assert_equal relation.preload_values + relation.includes_values, Message.rendering_associations
    assert_includes Message.rendering_associations, :room
    assert Message.rendering_associations.any? { |spec| spec.is_a?(Hash) && spec.key?(:boosts) }
  end

  private
    def create_messages(count, offset: 0)
      Array.new(count) do |i|
        @room.messages.create!(creator: @people[(i + offset) % @people.size],
          client_message_id: "render-#{i + offset}", body: "rendered message #{i + offset}")
      end
    end

    # Everything messages/_message and its partials reach for.
    def touch_rendered_details(messages)
      messages.each do |message|
        message.creator.avatar_attachment
        message.body.to_s
        message.room.name
        message.ordered_boosts.each { |boost| boost.booster.name }
        message.reply_to_message&.then { |source| [ source.body.to_s, source.creator.avatar_attachment ] }
      end
    end

    def count_queries
      count = 0
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
      end

      # The query cache persists across calls inside a test and would otherwise
      # hide a repeated query behind a cache hit.
      ActiveRecord::Base.connection_pool.clear_query_cache
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
end
