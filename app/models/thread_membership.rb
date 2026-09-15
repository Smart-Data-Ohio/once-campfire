class ThreadMembership < ApplicationRecord
  belongs_to :thread, class_name: "ChannelThread"
  belongs_to :user

  enum :involvement, %w[ nothing mentions everything ].index_by(&:itself), prefix: :involved_in

  scope :unread, -> { where.not(unread_at: nil) }

  before_validation -> { self.joined_at ||= Time.current }
  validate :user_is_a_parent_room_member

  class << self
    def join!(thread, user)
      thread.room.memberships.find_by!(user_id: user.id)

      find_or_create_by!(thread:, user:) do |membership|
        membership.joined_at = Time.current
      end
    end
  end

  def read
    update!(unread_at: nil)
  end

  def unread?
    unread_at.present?
  end

  private
    def user_is_a_parent_room_member
      return if thread.blank? || user.blank? || thread.room.memberships.exists?(user_id: user.id)

      errors.add :user, "must belong to the parent room"
    end
end
