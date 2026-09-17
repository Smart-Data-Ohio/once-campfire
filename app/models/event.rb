class Event < ApplicationRecord
  TIME_CHANGE_ATTRIBUTES = %w[ starts_at ends_at time_zone ].freeze
  NOTIFYING_RESPONSES = %w[ going maybe ].freeze

  # Recurrence fields reject plain update/update! calls unless the save runs
  # inside #with_recurrence_mutation (see #recurrence_fields_require_scoped_api).
  belongs_to :room
  belongs_to :organizer, class_name: "User"

  has_many :attendances, class_name: "EventAttendance", dependent: :destroy, inverse_of: :event
  has_many :attendees, through: :attendances, source: :user
  has_many :calendar_entries, class_name: "EventCalendarEntry", dependent: :destroy
  has_many :activity_items, as: :source, dependent: :destroy, inverse_of: :source

  validates :title, presence: true
  validates :starts_at, presence: true
  validates :time_zone, presence: true
  validates :recurrence_rule, inclusion: { in: Event::Recurrence::RULES }, allow_nil: true
  validate :time_zone_must_be_valid
  validate :ends_at_must_follow_starts_at
  validate :organizer_must_be_eligible
  validate :recurrence_until_requirements, if: :validates_recurrence_range?
  validate :recurrence_occurrence_cap, if: :validates_recurrence_range?
  validate :series_head_must_keep_rule
  validate :recurrence_fields_require_scoped_api, on: :update
  validate :series_order_must_be_preserved, on: :update

  before_validation :normalize_recurrence_rule

  scope :active, -> { where(cancelled_at: nil) }
  scope :upcoming, -> { active.where("COALESCE(events.ends_at, events.starts_at) >= ?", Time.current) }
  scope :past, -> { active.where("COALESCE(events.ends_at, events.starts_at) < ?", Time.current) }
  scope :cancelled, -> { where.not(cancelled_at: nil) }
  scope :ordered, -> { order(starts_at: :desc, id: :desc) }
  scope :soonest_first, -> { order(starts_at: :asc, id: :asc) }

  after_create :record_organizer_attendance
  after_create :materialize_series, if: :materializes_series?
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

  def series?
    series_id.present?
  end

  def series_head?
    series? && series_id == id
  end

  def series_events
    return Event.where(id:) unless series?

    # At equal times uncancelled occurrences sort first, so navigation never
    # prefers a cancelled row sharing a slot with an active one.
    Event.where(series_id:).order(:starts_at, Event.arel_table[:cancelled_at].asc.nulls_first, :id)
  end

  def future_occurrences
    return Event.none unless series?

    series_events.where(
      "events.starts_at > :starts OR (events.starts_at = :starts AND events.id > :id)",
      starts: starts_at, id:
    )
  end

  def previous_occurrence
    return nil unless series?

    series_events.where(
      "events.starts_at < :starts OR (events.starts_at = :starts AND events.id < :id)",
      starts: starts_at, id:
    ).last
  end

  def next_occurrence
    future_occurrences.first
  end

  # A response on the first event is copied to every future occurrence at that
  # moment; elsewhere the response stays local unless apply_to_future is set.
  def respond!(user, response, apply_to_future: false)
    transaction do
      attendance = attendances.find_or_initialize_by(user: user)
      attendance.response = response
      attendance.save!
      copy_response_to_future!(user, response) if series? && (series_head? || apply_to_future)
      attendance
    end
  end

  def copy_response_to_future!(user, response)
    future_occurrences.each do |occurrence|
      next if occurrence.cancelled?

      attendance = occurrence.attendances.find_or_initialize_by(user: user)
      next if attendance.persisted? && attendance.response == response.to_s

      attendance.response = response
      attendance.save!
    end
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

  def update_with_scope!(attributes, scope:, actor:)
    scope = scope.to_s.presence_in(Event::Recurrence::SCOPES) || "this_event"

    if series? && scope == "this_and_following"
      update_series_and_following!(attributes, actor:)
    else
      if (message = recurrence_change_rejection(attributes))
        errors.add(:recurrence_rule, message)
        raise ActiveRecord::RecordInvalid, self
      end
      update_with_announcement!(attributes, actor:)
    end
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

  def cancel_with_scope!(scope:, actor:)
    scope = scope.to_s.presence_in(Event::Recurrence::SCOPES) || "this_event"
    return cancel!(actor:) unless series? && scope == "this_and_following"
    return false if cancelled?

    transaction do
      targets = [ self ] + future_occurrences.to_a
      targets.reject!(&:cancelled?)
      targets.each do |occurrence|
        occurrence.update!(cancelled_at: Time.current)
        occurrence.activity_items.unread.find_each(&:mark_handled!)
        occurrence.calendar_entries.pluck(:user_id).each do |user_id|
          Calendar::SyncEntryJob.perform_later(occurrence.id, user_id)
        end
      end

      series_notification_recipients(targets.map(&:id), actor:).find_each do |attendee|
        transition_activity_item!(attendee, "event_cancelled")
      end
    end

    true
  end

  def remind_attendees!
    notification_recipients.find_each do |attendee|
      transition_activity_item!(attendee, "event_reminder")
    end
  end

  def sync_calendar_entries!
    attendances.where(response: NOTIFYING_RESPONSES).joins(user: :google_account)
      .where(google_accounts: { disconnected_reason: nil }).pluck(:user_id)
      .each { |user_id| Calendar::SyncEntryJob.perform_later(id, user_id) }
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

    # Every occurrence carries the series rule and end date, but the range only
    # constrains the head: later occurrences start nearer to (or on) the end.
    def validates_recurrence_range?
      recurrence_rule.present? && (series_id.blank? || series_id == id)
    end

    def recurrence_until_requirements
      if recurrence_until.blank?
        errors.add :recurrence_until, :blank
        return
      end
      return if starts_at.blank? || (zone = ActiveSupport::TimeZone[time_zone]).nil?

      start_date = starts_at.in_time_zone(zone).to_date
      if recurrence_until <= start_date
        errors.add :recurrence_until, "must be after the start date"
      elsif recurrence_until > start_date.next_year
        errors.add :recurrence_until, "must be at most one year after the start date"
      end
    end

    def recurrence_occurrence_cap
      return if starts_at.blank? || recurrence_until.blank?
      return if time_zone.blank? || ActiveSupport::TimeZone[time_zone].nil?

      count = Event::Recurrence.occurrence_count(
        starts_at:, time_zone:, rule: recurrence_rule, until_date: recurrence_until
      )
      return if count <= Event::Recurrence::MAX_OCCURRENCES

      errors.add :recurrence_until,
        "would create #{count} occurrences (maximum #{Event::Recurrence::MAX_OCCURRENCES}); pick an earlier end date"
    end

    def series_head_must_keep_rule
      return unless persisted? && series_id.present? && series_id == id && recurrence_rule.blank?

      errors.add :recurrence_rule, "can't be removed from a repeating event"
    end

    def series_order_must_be_preserved
      return unless series_id.present? && will_save_change_to_starts_at?
      return if @skip_series_order_validation

      siblings = Event.where(series_id:, cancelled_at: nil).where.not(id:)
      anchor = starts_at_was || starts_at
      previous = siblings.where("events.starts_at < ?", anchor).order(:starts_at).last
      if previous && starts_at <= previous.starts_at
        errors.add :starts_at, "must stay between the neighbouring occurrences in its series"
        return
      end
      # "This and following" shifts every follower by the same offset, so only
      # the previous-sibling bound applies there.
      return if @following_reorder

      following = siblings.where("events.starts_at > ?", anchor).order(:starts_at).first
      if following && starts_at >= following.starts_at
        errors.add :starts_at, "must stay between the neighbouring occurrences in its series"
      end
    end

    def recurrence_fields_require_scoped_api
      return if @allow_recurrence_mutation

      errors.add :recurrence_rule, recurrence_direct_change_message if will_save_change_to_recurrence_rule?
      errors.add :recurrence_until, recurrence_direct_change_message if will_save_change_to_recurrence_until?
      errors.add :series_id, "cannot be changed" if will_save_change_to_series_id?
    end

    def recurrence_direct_change_message
      if series?
        "can only be changed from the first event in the series using This and following"
      else
        "can only be set when scheduling a new event"
      end
    end

    def normalize_recurrence_rule
      self.recurrence_rule = recurrence_rule.presence
    end

    def materializes_series?
      recurrence_rule.present? && series_id.blank?
    end

    def materialize_series
      self.series_id = id
      update_column(:series_id, id)
      Event::Recurrence.slots(
        starts_at:, ends_at:, time_zone:,
        rule: recurrence_rule, until_date: recurrence_until
      ).drop(1).each do |(slot_starts, slot_ends)|
        room.events.create!(
          organizer:, title:, description:,
          starts_at: slot_starts, ends_at: slot_ends, time_zone:,
          series_id: id, recurrence_rule:, recurrence_until:
        )
      end
    end

    def record_organizer_attendance
      attendances.create!(user: organizer, response: :going)
    end

    def fan_out_invitations
      return if series_id.present? && series_id != id

      invitation_recipients.find_each do |recipient|
        ActivityItem.create_or_find_by!(user: recipient, source: self) do |item|
          item.event_type = "event_invitation"
        end
      end
    end

    def recurrence_change_rejection(attributes)
      assign_attributes(attributes)
      return nil unless will_save_change_to_recurrence_rule? || will_save_change_to_recurrence_until?

      recurrence_direct_change_message
    end

    # Scoped series writes run inside these blocks. The flags live only in
    # instance variables and are always cleared, so nothing outside the model
    # can set them and they never leak into later saves.
    def with_recurrence_mutation
      @allow_recurrence_mutation = true
      yield
    ensure
      @allow_recurrence_mutation = false
    end

    def with_following_reorder
      @following_reorder = true
      yield
    ensure
      @following_reorder = false
    end

    def without_series_order_validation
      @skip_series_order_validation = true
      yield
    ensure
      @skip_series_order_validation = false
    end

    def with_series_follower_save
      with_recurrence_mutation { without_series_order_validation { yield } }
    end

    def update_series_and_following!(attributes, actor:)
      time_changed = false

      transaction do
        # Snapshot this occurrence and every later one in series order before
        # any attribute is saved, and use that id list for the whole
        # operation: moving this occurrence later must not skip its original
        # followers, and moving it earlier must never touch previous ones.
        scope_ids = [ id ] + future_occurrences.ids
        assign_attributes(attributes)

        if will_save_change_to_recurrence_rule? || will_save_change_to_recurrence_until?
          unless series_head?
            errors.add(:recurrence_rule, "can only be changed from the first event in the series using This and following")
            raise ActiveRecord::RecordInvalid, self
          end
        end

        rule_changed = will_save_change_to_recurrence_rule? || will_save_change_to_recurrence_until?
        time_changed = TIME_CHANGE_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }
        title_changed = will_save_change_to_title?
        description_changed = will_save_change_to_description?
        zone_changed = will_save_change_to_time_zone?
        starts_delta = will_save_change_to_starts_at? ? starts_at - starts_at_was : 0
        ends_delta = will_save_change_to_ends_at? && ends_at.present? && ends_at_was.present? ? ends_at - ends_at_was : nil
        ends_added = will_save_change_to_ends_at? && ends_at_was.nil?
        ends_removed = will_save_change_to_ends_at? && ends_at.nil?

        self.reminded_at = nil if time_changed
        with_following_reorder { with_recurrence_mutation { save! } }

        followers = Event.where(id: scope_ids - [ id ]).includes(:attendances).order(:starts_at, :id).to_a
        followers.each do |occurrence|
          occurrence.title = title if title_changed
          occurrence.description = description if description_changed
          occurrence.time_zone = time_zone if zone_changed
          shift_occurrence_times!(occurrence, starts_delta:, ends_delta:, ends_added:, ends_removed:)
          occurrence.recurrence_rule = recurrence_rule if rule_changed
          occurrence.recurrence_until = recurrence_until if rule_changed
          occurrence.reminded_at = nil if time_changed
          occurrence.send(:with_series_follower_save) { occurrence.save! }
        end

        synced_ids = rule_changed ? rematerialize_series!(followers, actor:, time_changed:) : []
        announce_series_change!(actor:, scope_ids:) if time_changed || rule_changed

        ([ self ] + followers).each do |event|
          next if event.destroyed?
          next if synced_ids.include?(event.id)
          next if event.saved_change_to_cancelled_at?
          next unless (Calendar::EntrySync::SYNCED_ATTRIBUTES & event.saved_changes.keys).any?

          event.sync_calendar_entries!
        end
      end

      time_changed
    end

    # Later occurrences move with the edited one: their starts shift by the
    # starts delta, and their ends follow the ends delta when the duration
    # changed, otherwise the starts delta so durations are preserved.
    def shift_occurrence_times!(occurrence, starts_delta:, ends_delta:, ends_added:, ends_removed:)
      return if starts_delta.zero? && ends_delta.nil? && !ends_added && !ends_removed

      occurrence.starts_at = occurrence.starts_at + starts_delta unless starts_delta.zero?

      if ends_removed
        occurrence.ends_at = nil
      elsif ends_added
        occurrence.ends_at = occurrence.starts_at + (ends_at - starts_at)
      elsif ends_delta
        occurrence.ends_at = occurrence.ends_at + ends_delta if occurrence.ends_at
      elsif !starts_delta.zero? && occurrence.ends_at
        occurrence.ends_at = occurrence.ends_at + starts_delta
      end
    end

    # Rebuilds the future occurrences after a rule or end-date change on the
    # head. Cancelled occurrences keep their slots: a cancelled row on a
    # desired slot removes that slot from the pool and is neither re-timed nor
    # deleted. Occurrences where anyone responded differently from the head
    # keep their ids and responses: those already on a desired slot stay put
    # and the rest move onto the remaining slots in series order, while
    # protected occurrences beyond the slot count are cancelled through the
    # normal cancellation path so their attendees are notified. Regenerable
    # occurrences are reused in place, retimed onto a new slot (keeping their
    # calendar entries), or removed when the series shrank; remaining slots
    # are created with the head's responses. Removals and cancellations run
    # before any move, so a moved row never lands on a slot another row still
    # occupies. Returns the ids already synced to calendars here, so the
    # caller does not sync them twice.
    def rematerialize_series!(followers, actor:, time_changed:)
      desired = Event::Recurrence.slots(
        starts_at:, ends_at:, time_zone:,
        rule: recurrence_rule, until_date: recurrence_until
      ).drop(1)

      later = followers.sort_by { |occurrence| [ occurrence.starts_at, occurrence.id ] }
      head_responses = attendances.map { |attendance| [ attendance.user_id, attendance.response ] }.to_h
      protected_occurrences, regenerable = later.reject(&:cancelled?).partition do |occurrence|
        occurrence.attendances.map { |attendance| [ attendance.user_id, attendance.response ] }.to_h != head_responses
      end

      unmatched_slots = desired.dup
      claim_slot = lambda do |starts|
        index = unmatched_slots.index { |(slot_starts, _)| slot_starts == starts }
        index ? unmatched_slots.delete_at(index) : nil
      end

      later.select(&:cancelled?).each { |occurrence| claim_slot.call(occurrence.starts_at) }

      moves = []
      cancels = []
      destroys = []

      protected_occurrences.reject { |occurrence| claim_slot.call(occurrence.starts_at) }.each do |occurrence|
        if (slot = unmatched_slots.shift)
          moved = slot.first != occurrence.starts_at || slot.second != occurrence.ends_at
          moves << [ occurrence, slot, time_changed || moved ]
        else
          cancels << occurrence
        end
      end

      regenerable.reject { |occurrence| claim_slot.call(occurrence.starts_at) }.each do |occurrence|
        if (slot = unmatched_slots.shift)
          moves << [ occurrence, slot, true ]
        else
          destroys << occurrence
        end
      end

      destroys.each(&:destroy!)
      cancels.each { |occurrence| occurrence.cancel!(actor:) }
      synced_ids = moves.filter_map do |(occurrence, slot, rearm_reminder)|
        occurrence.id if retime_occurrence!(occurrence, slot, rearm_reminder:)
      end

      unmatched_slots.each do |(slot_starts, slot_ends)|
        room.events.create!(
          organizer:, title:, description:,
          starts_at: slot_starts, ends_at: slot_ends, time_zone:,
          series_id: id, recurrence_rule:, recurrence_until:
        ).tap { |occurrence| copy_attendances_to!(occurrence) }
      end

      synced_ids
    end

    # Moves an occurrence onto a rebuilt slot and syncs its calendar entries
    # when the earlier shift or this retime touched a synced attribute.
    # Returns true when synced, so the caller does not sync it twice.
    def retime_occurrence!(occurrence, slot, rearm_reminder:)
      shift_synced = (Calendar::EntrySync::SYNCED_ATTRIBUTES & occurrence.saved_changes.keys).any?
      attributes = { starts_at: slot.first, ends_at: slot.second }
      attributes[:reminded_at] = nil if rearm_reminder
      occurrence.send(:without_series_order_validation) { occurrence.update!(attributes) }

      if shift_synced || (Calendar::EntrySync::SYNCED_ATTRIBUTES & occurrence.saved_changes.keys).any?
        occurrence.sync_calendar_entries!
        true
      else
        false
      end
    end

    def copy_attendances_to!(occurrence)
      attendances.each do |attendance|
        existing = occurrence.attendances.find_or_initialize_by(user_id: attendance.user_id)
        next if existing.persisted? && existing.response == attendance.response

        existing.response = attendance.response
        existing.save!
      end
    end

    def announce_time_change!(actor:)
      notification_recipients.where.not(id: actor&.id).find_each do |attendee|
        transition_activity_item!(attendee, "event_update")
      end
    end

    # One Event update item per attendee for the series, attached to the edited
    # occurrence, replacing every earlier unhandled update item for any
    # occurrence in the series, whether read or not.
    def announce_series_change!(actor:, scope_ids:)
      series_ids = series_events.ids

      series_notification_recipients(scope_ids, actor:).find_each do |attendee|
        ActivityItem.where(user: attendee, event_type: "event_update", source_type: Event.polymorphic_name, source_id: series_ids, handled_at: nil)
          .find_each(&:mark_handled!)
        transition_activity_item!(attendee, "event_update")
      end
    end

    def series_notification_recipients(scope_ids, actor:)
      User.active.without_bots
        .where(id: EventAttendance.where(event_id: scope_ids, response: NOTIFYING_RESPONSES).select(:user_id))
        .where(id: room.memberships.select(:user_id))
        .where.not(id: actor&.id)
    end

    def invitation_recipients
      room.users.active.without_bots.where.not(id: organizer_id)
    end

    def notification_recipients
      User.active.without_bots
        .where(id: attendances.where(response: NOTIFYING_RESPONSES).select(:user_id))
        .where(id: room.memberships.select(:user_id))
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
