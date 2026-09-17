class EventAttendance < ApplicationRecord
  belongs_to :event
  belongs_to :user

  enum :response, %w[ going maybe declined ].index_by(&:itself)

  validates :user_id, uniqueness: { scope: :event_id }
  validate :event_must_be_open
  validate :user_must_be_active_human
  validate :user_must_be_room_member

  private
    def event_must_be_open
      errors.add :event, "is cancelled" if event&.cancelled?
    end

    def user_must_be_active_human
      return if user&.active? && !user.bot?

      errors.add :user, "must be an active human"
    end

    def user_must_be_room_member
      return if event.blank? || user.blank?
      return if event.room.memberships.exists?(user_id: user.id)

      errors.add :user, "must be a member of the event room"
    end
end
