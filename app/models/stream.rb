# A stage channel live stream: a host or speaker presenting their screen at
# an explicit quality. One room carries at most one live stream, enforced by
# a partial unique index on room_id where ended_at IS NULL. Ended rows stay
# as history; `live` is the current broadcast, if any.
#
# Starting and ending broadcast the same three updates: the room header's
# Live badge on the room's messages stream, and the sidebar live dot plus a
# per-viewer stage panel on every member's own rooms stream. Automatic ends
# (demotion, removal, deactivation, grant revocation) go through the same
# callbacks, so every path delivers identical updates.
class Stream < ApplicationRecord
  QUALITIES = %w[ 720p15 1080p15 1080p30 ].freeze

  belongs_to :room
  belongs_to :membership
  belongs_to :user

  validates :quality, inclusion: { in: QUALITIES }

  before_validation :set_started_at, on: :create

  scope :live, -> { where(ended_at: nil) }

  # Create and update need distinct callback filters: registering the same
  # method twice on the commit chain keeps only one registration.
  after_create_commit :broadcast_stream_started
  after_update_commit :broadcast_stream_ended, if: :saved_change_to_ended_at?

  class << self
    # Ends the membership's live stream in its room, if any. Called from the
    # role-change path when a presenter is demoted to listener.
    def end_live_for_membership!(membership)
      live.where(room_id: membership.room_id, membership_id: membership.id).each(&:end!)
    end

    # Ends every stream the user presents, across rooms. Called from user
    # deactivation, which removes every membership.
    def end_live_for_user!(user)
      live.where(user_id: user.id).each(&:end!)
    end

    # Ends the grant holder's stream once their last active grant for the
    # room goes away. Called from HuddleGrant#revoke!, in the same
    # transaction, so membership removal, deactivation, demotion, session
    # revocation, and gateway enforcement all funnel through here.
    def end_when_last_grant_revoked(grant)
      return if grant.room_id.nil? || grant.membership_id.nil?
      return if HuddleGrant.active.where(room_id: grant.room_id, membership_id: grant.membership_id).exists?

      live.where(room_id: grant.room_id, membership_id: grant.membership_id).each(&:end!)
    end
  end

  def live?
    ended_at.nil?
  end

  def end!
    update!(ended_at: Time.current) if live?
  end

  private
    def set_started_at
      self.started_at ||= Time.current
    end

    def broadcast_stream_started
      broadcast_stream_changed
    end

    def broadcast_stream_ended
      broadcast_stream_changed
    end

    # The header badge is identical for every viewer, so it goes to the
    # room's stream once. The sidebar dot and the stage panel (whose Stop
    # button renders only for the presenter and hosts) go to each member's
    # own stream, mirroring the voice presence and stage roster broadcasts.
    def broadcast_stream_changed
      stage_room = Room.find_by(id: room_id)
      return unless stage_room.is_a?(Rooms::Stage)

      broadcast_replace_to stage_room, :messages,
        target: [ stage_room, :stage_live_badge ],
        partial: "rooms/stage/live_badge",
        locals: { room: stage_room }

      stage_room.memberships.includes(:user).find_each do |member|
        broadcast_replace_to member.user, :rooms,
          target: [ stage_room, :sidebar_stage_live ],
          partial: "rooms/stage/live_dot",
          locals: { room: stage_room }
        broadcast_replace_to member.user, :rooms,
          target: [ stage_room, :stage_panel ],
          partial: "rooms/stage/panel_body",
          locals: { room: stage_room, membership: member, rejoin: false }
      end
    end
end
