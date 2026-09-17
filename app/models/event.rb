class Event < ApplicationRecord
  TIME_CHANGE_ATTRIBUTES = %w[ starts_at ends_at time_zone ].freeze
  NOTIFYING_RESPONSES = %w[ going maybe ].freeze

  belongs_to :room
  belongs_to :organizer, class_name: "User"

  has_many :attendances, class_name: "EventAttendance", dependent: :destroy, inverse_of: :event
  has_many :attendees, through: :attendances, source: :user
  has_many :calendar_entries, class_name: "EventCalendarEntry", dependent: :destroy
  has_many :activity_items, as: :source, dependent: :destroy, inverse_of: :source

  validates :title, presence: true
  validates :starts_at, presence: true
  validates :time_zone, presence: true
  validate :time_zone_must_be_valid
  validate :ends_at_must_follow_starts_at
  validate :organizer_must_be_eligible

  scope :active, -> { where(cancelled_at: nil) }
  scope :upcoming, -> { active.where("COALESCE(events.ends_at, events.starts_at) >= ?", Time.current) }
  scope :past, -> { active.where("COALESCE(events.ends_at, events.starts_at) < ?", Time.current) }
  scope :cancelled, -> { where.not(cancelled_at: nil) }
  scope :ordered, -> { order(starts_at: :desc, id: :desc) }
  scope :soonest_first, -> { order(starts_at: :asc, id: :asc) }

  after_create :record_organizer_attendance
  after_create_commit :fan_out_invitations

  def cancelled?
    cancelled_at.present?
  end

  def manageable_by?(user)
    return false if cancelled?

    cancellable_by?(user)
  end

  def cancellable_by?(user)
    return false unless user&.active? && !user.bot?

    organizer_id == user.id || user.administrator?
  end

  def respondable_by?(user)
    return false unless user&.active? && !user.bot?
    return false if cancelled?

    room.memberships.exists?(user_id: user.id)
  end

  def response_for(user)
    attendances.find_by(user_id: user&.id)&.response
  end

  def attendance_counts
    attendances.group(:response).count
  end

  # Time edits notify going/maybe attendees and re-arm the reminder; plain
  # title/description edits stay silent.
  def update_with_announcement!(attributes, actor:)
    time_changed = false

    transaction do
      assign_attributes(attributes)
      time_changed = TIME_CHANGE_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }
      self.reminded_at = nil if time_changed
      save!
      announce_time_change!(actor:) if time_changed
      sync_calendar_entries! if Calendar::EntrySync::SYNCED_ATTRIBUTES.any? { |attribute| saved_change_to_attribute?(attribute) }
    end

    time_changed
  end

  def cancel!(actor:)
    return false if cancelled?

    transaction do
      update!(cancelled_at: Time.current)
      activity_items.unread.find_each(&:mark_handled!)
      notification_recipients.where.not(id: actor&.id).find_each do |attendee|
        transition_activity_item!(attendee, "event_cancelled")
      end
      calendar_entries.pluck(:user_id).each { |user_id| Calendar::SyncEntryJob.perform_later(id, user_id) }
    end

    true
  end

  def remind_attendees!
    notification_recipients.find_each do |attendee|
      next unless attendee.inbox_preferences.event_reminders

      transition_activity_item!(attendee, "event_reminder")
    end
  end

  private
    def time_zone_must_be_valid
      return if time_zone.blank? || ActiveSupport::TimeZone[time_zone].present?

      errors.add :time_zone, "is invalid"
    end

    def ends_at_must_follow_starts_at
      return if ends_at.blank? || starts_at.blank?
      return if ends_at > starts_at

      errors.add :ends_at, "must be after the start time"
    end

    def organizer_must_be_eligible
      return if organizer&.active? && !organizer.bot? && room&.memberships&.exists?(user_id: organizer_id)

      errors.add :organizer, "must be an active human member of the room"
    end

    def record_organizer_attendance
      attendances.create!(user: organizer, response: :going)
    end

    def fan_out_invitations
      invitation_recipients.find_each do |recipient|
        ActivityItem.create_or_find_by!(user: recipient, source: self) do |item|
          item.event_type = "event_invitation"
        end
      end
    end

    def announce_time_change!(actor:)
      notification_recipients.where.not(id: actor&.id).find_each do |attendee|
        transition_activity_item!(attendee, "event_update")
      end
    end

    def sync_calendar_entries!
      attendances.where(response: NOTIFYING_RESPONSES).joins(user: :google_account)
        .where(google_accounts: { disconnected_reason: nil }).pluck(:user_id)
        .each { |user_id| Calendar::SyncEntryJob.perform_later(id, user_id) }
    end

    def invitation_recipients
      room.users.active.without_bots.where.not(id: organizer_id)
        .where(id: notified_member_ids)
    end

    def notification_recipients
      User.active.without_bots
        .where(id: attendances.where(response: NOTIFYING_RESPONSES).select(:user_id))
        .where(id: room.memberships.select(:user_id))
        .where(id: notified_member_ids)
    end

    # Event items honour room involvement like the rest of the inbox:
    # members with notifications off or invisible get no invitation,
    # update, cancellation, or reminder items from this room.
    def notified_member_ids
      room.memberships.where.not(involvement: %w[ nothing invisible ]).select(:user_id)
    end

    # Activity items are unique per recipient + source, so a later lifecycle
    # step reuses the recipient's row for this event instead of stacking a
    # second unhandled item beside the invitation.
    def transition_activity_item!(user, event_type)
      attempts = 0
      begin
        ActivityItem.transaction do
          item = ActivityItem.lock.find_or_initialize_by(user: user, source: self)
          item.event_type = event_type
          item.read_at = nil
          item.handled_at = nil
          item.save!
          item
        end
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        retry if attempts < 2
        raise
      end
    end
end
