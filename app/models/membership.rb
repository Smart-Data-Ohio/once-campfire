class Membership < ApplicationRecord
  include Connectable

  belongs_to :room
  belongs_to :user

  before_destroy :capture_huddle_revocations
  after_destroy_commit { user.reset_remote_connections }
  after_destroy_commit :revoke_huddle_participants

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
    def capture_huddle_revocations
      @huddle_revocations = Huddle.participant_revocations(room_ids: [ room_id ], session_ids: user.session_ids)
    end

    def revoke_huddle_participants
      Huddle.enqueue_participant_revocations(@huddle_revocations)
    end
end
