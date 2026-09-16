class Membership < ApplicationRecord
  include Connectable

  belongs_to :room
  belongs_to :user

  before_destroy -> { HuddleGrant.revoke_for_membership!(self) }
  before_destroy -> { AgentGrant.revoke_for_membership!(self) }
  after_destroy_commit :reset_user_remote_connections
  after_destroy_commit :remove_thread_membership

  enum :involvement, %w[ invisible nothing mentions everything ].index_by(&:itself), prefix: :involved_in

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

  private
    def reset_user_remote_connections
      user.reset_remote_connections
    end

    def remove_thread_membership
      ThreadMembership
        .joins(:thread)
        .where(user_id: user_id, channel_threads: { room_id: room_id })
        .delete_all
    end
end
