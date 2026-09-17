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
    # Drop the removed member's sidebar row over their existing rooms stream,
    # the same stream the involvement toggle uses. Voice rooms also drop the
    # header presence stack first: unlike the row, nothing else refreshes it.
    def broadcast_room_removal_to_user
      broadcast_remove_to user, :rooms, target: [ room, :header_voice_participants ] if room.voice?
      broadcast_remove_to user, :rooms, target: [ room, :list ]
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
end
