class ActivityItem < ApplicationRecord
  EVENT_TYPES = %w[ mention reply thread_activity work_update work_assignment huddle_started huddle_missed ].freeze
  HUDDLE_EVENT_TYPES = %w[ huddle_started huddle_missed ].freeze
  FILTERS = %w[ unread read handled ].freeze

  belongs_to :user
  belongs_to :source, polymorphic: true

  validates :event_type, inclusion: { in: EVENT_TYPES }

  after_create_commit :broadcast_created
  after_update_commit :broadcast_updated

  # The cursor is the last item ID, so keep the ordering on that same stable
  # key. Event timestamps can be supplied by imports or delayed transactions.
  scope :ordered, -> { order(id: :desc) }
  scope :unread, -> { where(read_at: nil, handled_at: nil) }
  scope :read, -> { where.not(read_at: nil).where(handled_at: nil) }
  scope :handled, -> { where.not(handled_at: nil) }
  scope :message_sources, -> { where(source_type: Message.polymorphic_name) }
  scope :supported_sources, -> { where(source_type: [ Message.polymorphic_name, "WorkThreadEvent", HuddleGrant.polymorphic_name ]) }

  class << self
    # Source data is deliberately resolved from the source row at query time.
    # Keeping only the recipient, source identity, event type, and state means
    # a private message cannot remain readable in a deleted or revoked room.
    def accessible_to(user)
      return none unless active_human?(user)

      supported_sources
        .joins(:user)
        .joins(<<~SQL.squish)
          LEFT JOIN messages AS activity_messages
            ON activity_messages.id = activity_items.source_id
            AND activity_items.source_type = #{connection.quote(Message.polymorphic_name)}
          LEFT JOIN memberships AS activity_message_memberships
            ON activity_message_memberships.room_id = activity_messages.room_id
            AND activity_message_memberships.user_id = activity_items.user_id
          LEFT JOIN work_thread_events AS activity_work_events
            ON activity_work_events.id = activity_items.source_id
            AND activity_items.source_type = #{connection.quote("WorkThreadEvent")}
          LEFT JOIN channel_threads AS activity_work_threads
            ON activity_work_threads.id = activity_work_events.channel_thread_id
          LEFT JOIN memberships AS activity_work_memberships
            ON activity_work_memberships.room_id = activity_work_threads.room_id
            AND activity_work_memberships.user_id = activity_items.user_id
          LEFT JOIN huddle_grants AS activity_huddle_grants
            ON activity_huddle_grants.id = activity_items.source_id
            AND activity_items.source_type = #{connection.quote(HuddleGrant.polymorphic_name)}
          LEFT JOIN memberships AS activity_huddle_memberships
            ON activity_huddle_memberships.room_id = activity_huddle_grants.room_id
            AND activity_huddle_memberships.user_id = activity_items.user_id
        SQL
        .merge(User.active.without_bots)
        .where(activity_items: { user_id: user.id })
        .where(<<~SQL.squish)
          (activity_items.source_type = #{connection.quote(Message.polymorphic_name)} AND activity_message_memberships.id IS NOT NULL)
          OR (activity_items.source_type = #{connection.quote("WorkThreadEvent")} AND activity_work_memberships.id IS NOT NULL)
          OR (activity_items.source_type = #{connection.quote(HuddleGrant.polymorphic_name)} AND activity_huddle_memberships.id IS NOT NULL)
        SQL
        .distinct
    end

    def active_human?(user)
      user&.active? && !user.bot?
    end
  end

  def unread?
    read_at.blank? && handled_at.blank?
  end

  def read?
    read_at.present? && handled_at.blank?
  end

  def handled?
    handled_at.present?
  end

  def state
    return "handled" if handled?
    return "read" if read_at.present?

    "unread"
  end

  def mark_read!
    update!(read_at: Time.current) unless read_at.present?
    self
  end

  def mark_unread!
    if read_at.present? || handled_at.present?
      update!(read_at: nil, handled_at: nil)
    end
    self
  end

  def mark_handled!
    update!(read_at: read_at || Time.current, handled_at: Time.current)
    self
  end

  def mark_unhandled!
    update!(handled_at: nil) if handled_at.present?
    self
  end

  private
    def broadcast_created
      broadcast_activity_change
    end

    def broadcast_updated
      return unless saved_change_to_read_at? || saved_change_to_handled_at? || saved_change_to_event_type?

      broadcast_activity_change
    end

    def broadcast_activity_change
      return unless ActivityItem.active_human?(user)

      ActionCable.server.broadcast ActivityChannel.stream_name_for(user_id), activity_broadcast_payload
    end

    # The inbox and badge subscribers only read `activityItemId`. Huddle items
    # carry an extra invitation payload so the incoming-huddle banner can ring
    # without another request; other subscribers ignore the unknown key.
    def activity_broadcast_payload
      { activityItemId: id }.merge(huddle_invitation_broadcast)
    end

    def huddle_invitation_broadcast
      return {} unless HUDDLE_EVENT_TYPES.include?(event_type)
      return {} unless source_type == HuddleGrant.polymorphic_name

      grant = source
      room = grant&.room
      caller = grant&.user
      return {} unless grant && room && caller

      routes = Rails.application.routes.url_helpers
      {
        huddleInvitation: {
          activityItemId: id,
          eventType: event_type,
          state: state,
          roomId: room.id,
          roomName: huddle_invitation_room_name(room),
          roomPath: routes.room_path(room),
          callerName: caller.name,
          readPath: routes.read_activity_item_path(self, state: "read"),
          handledPath: routes.handled_activity_item_path(self, state: "handled")
        }
      }
    end

    def huddle_invitation_room_name(room)
      if room.direct?
        room.users.without(user).pluck(:name).to_sentence.presence || user.name
      else
        room.name
      end
    end
end
