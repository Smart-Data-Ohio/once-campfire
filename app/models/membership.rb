class Membership < ApplicationRecord
  include Connectable

  belongs_to :room
  belongs_to :user

  before_destroy -> { HuddleGrant.revoke_for_membership!(self) }
  before_destroy -> { AgentGrant.revoke_for_membership!(self) }
  # The removal notice goes out before the connection reset below: once the
  # client processes the disconnect, broadcasts queued behind it are dropped.
  after_destroy_commit :broadcast_room_removal_to_user
  after_destroy_commit :reset_user_remote_connections
  after_destroy_commit :remove_thread_membership
  after_destroy_commit :sync_removed_room_calendar_entries

  enum :involvement, %w[ invisible nothing mentions everything ].index_by(&:itself), prefix: :involved_in

  # Stage roles only exist on stage-room memberships; every other room leaves
  # both stage columns nil. New stage members start as listeners.
  enum :stage_role, %w[ listener speaker host ].index_by(&:itself)

  before_validation :default_stage_role, on: :create
  before_update :revoke_huddle_grants_on_stage_role_change, if: :stage_role_changed?

  validate :stage_attributes_only_for_stage_rooms
  validate :raised_hands_only_for_listeners
  validate :at_least_one_host_remains, on: :update, if: :stage_role_changed?

  scope :with_ordered_room, -> { includes(:room).joins(:room).order("LOWER(rooms.name)") }
  scope :without_direct_rooms, -> { joins(:room).where.not(room: { type: "Rooms::Direct" }) }

  scope :visible, -> { where.not(involvement: :invisible) }
  scope :unread,  -> { where.not(unread_at: nil) }

  def read
    update!(unread_at: nil)
  end

  def unread?
    unread_at.present?
  end

  def raise_hand!
    update!(hand_raised_at: Time.current)
  end

  def lower_hand!
    update!(hand_raised_at: nil)
  end

  def hand_raised?
    hand_raised_at.present?
  end

  # Any role change clears a raised hand and, through the callback below,
  # revokes the member's active huddle grants in the same transaction, so the
  # gateway removes a demoted speaker and the client rejoins with a fresh
  # token for the new role.
  def change_stage_role!(new_role)
    update!(stage_role: new_role, hand_raised_at: nil)
  end

  private
    def default_stage_role
      self.stage_role ||= :listener if room&.stage?
    end

    def revoke_huddle_grants_on_stage_role_change
      HuddleGrant.revoke_for_membership!(self)
    end

    def stage_attributes_only_for_stage_rooms
      return if room&.stage?

      errors.add(:stage_role, "only exists on stage rooms") if stage_role.present?
      errors.add(:hand_raised_at, "only exists on stage rooms") if hand_raised_at.present?
    end

    def raised_hands_only_for_listeners
      if hand_raised_at.present? && stage_role != "listener"
        errors.add(:hand_raised_at, "can only be raised by a listener")
      end
    end

    def at_least_one_host_remains
      return unless stage_role_was == "host" && stage_role != "host"

      # The check runs inside the update transaction after locking the room:
      # without it, two concurrent demotions of the last two hosts could both
      # pass and strand the room. SQLite's immediate transaction mode
      # serializes writers, so the transaction plus a re-read inside it is
      # sufficient.
      room.lock!
      return if room.memberships.where(stage_role: :host).where.not(id: id).exists?

      errors.add(:stage_role, "can't demote the last host")
    end
    # Drop the removed member's sidebar row over their existing rooms stream,
    # the same stream the involvement toggle uses. Voice and stage rooms also
    # drop the header presence stack first: unlike the row, nothing else
    # refreshes it.
    # A failed broadcast (cable adapter outage) must never stop the
    # connection reset that follows: report it and let the callbacks run on.
    def broadcast_room_removal_to_user
      broadcast_remove_to user, :rooms, target: [ room, :header_voice_participants ] if room.voice? || room.stage?
      broadcast_remove_to user, :rooms, target: [ room, :list ]
    rescue StandardError => error
      Rails.error.report(error, handled: true, severity: :warning, context: { membership_id: id, room_id: room_id, user_id: user_id })
    end

    def reset_user_remote_connections
      user.reset_remote_connections
    end

    def remove_thread_membership
      ThreadMembership
        .joins(:thread)
        .where(user_id: user_id, channel_threads: { room_id: room_id })
        .delete_all
    end

    def sync_removed_room_calendar_entries
      EventCalendarEntry.where(user_id: user_id).joins(:event)
        .where(events: { room_id: room_id }).pluck(:event_id)
        .each { |event_id| Calendar::SyncEntryJob.perform_later(event_id, user_id) }
    end
end
