class HuddleGrant < ApplicationRecord
  class Ineligible < StandardError; end

  INVITATION_DEDUP_WINDOW = 2.minutes
  IN_CALL_WINDOW = 20.seconds
  SEEN_TOUCH_INTERVAL = 10.seconds

  belongs_to :session, optional: true
  belongs_to :user, optional: true
  belongs_to :membership, optional: true
  belongs_to :room, optional: true

  has_many :huddle_cleanups, dependent: :restrict_with_exception
  has_many :activity_items, as: :source, dependent: :destroy, inverse_of: :source

  scope :active, -> { where(revoked_at: nil) }
  scope :in_call, -> { where("last_seen_at > ?", IN_CALL_WINDOW.ago) }

  validates :identity, :room_name, presence: true
  validates :identity, uniqueness: true

  class << self
    def issue!(session:, membership:)
      attempts = 0

      begin
        grant = transaction do
          user = User.active.where.not(role: :bot).lock.find_by(id: session.user_id)
          current_session = Session.lock.find_by(id: session.id, user_id: user&.id)
          current_membership = Membership.lock.find_by(id: membership.id, user_id: user&.id, room_id: membership.room_id)
          current_room = Room.lock.find_by(id: current_membership&.room_id)

          raise Ineligible unless user && current_session && current_membership && current_room

          revoke_scope! active.where(session_id: current_session.id, room_id: current_room.id)
            .where.not(membership_id: current_membership.id)

          existing = active.find_by(session_id: current_session.id, membership_id: current_membership.id)
          if existing
            existing.update!(last_issued_at: Time.current)
            existing
          else
            create!(
              identity: "campfire-participant-#{SecureRandom.hex(32)}",
              room_name: Huddle.room_name(current_room.id),
              session_id: current_session.id,
              user_id: user.id,
              membership_id: current_membership.id,
              room_id: current_room.id,
              last_issued_at: Time.current
            )
          end
        end

        grant.after_issued!
        grant
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        retry if attempts < 3

        raise
      end
    end

    def revoke_for_membership!(membership)
      revoke_scope! active.where(membership_id: membership.id)
    end

    def revoke_for_session!(session)
      revoke_scope! active.where(session_id: session.id)
    end

    def revoke_for_user!(user)
      revoke_scope! active.where(user_id: user.id)
    end

    def revoke_for_room!(room)
      transaction do
        room_name = where(room_id: room.id).pick(:room_name)
        room_name ||= Huddle.room_name(room.id) if Huddle.token_signing_configured?

        revoke_scope! active.where(room_id: room.id), create_cleanup: false
        HuddleCleanup.create_room_deletion!(room_name) if room_name.present?
      end
    end

    private
      def revoke_scope!(scope, create_cleanup: true)
        scope.find_each { |grant| grant.revoke!(create_cleanup: create_cleanup) }
      end
  end

  def authorized?
    return false if revoked?

    User.active.where.not(role: :bot).exists?(id: user_id) &&
      Session.exists?(id: session_id, user_id: user_id) &&
      Membership.exists?(id: membership_id, user_id: user_id, room_id: room_id) &&
      Room.exists?(id: room_id)
  end

  def authorize_or_revoke!
    with_lock do
      return true if authorized?

      revoke!
      false
    end
  end

  def revoke!(create_cleanup: true)
    return if revoked?

    transaction do
      update!(revoked_at: Time.current)
      HuddleCleanup.create_participant_removal!(self) if create_cleanup
    end
  end

  def revoked?
    revoked_at.present?
  end

  def in_call?
    last_seen_at.present? && last_seen_at > IN_CALL_WINDOW.ago
  end

  # The gateway checks every connected participant about once per second, so
  # liveness is persisted at most every SEEN_TOUCH_INTERVAL.
  def record_seen!
    return if last_seen_at.present? && last_seen_at > SEEN_TOUCH_INTERVAL.ago

    update_columns(last_seen_at: Time.current)
  end

  # Post-commit work for every issuance, created or reused: obtaining a grant
  # means joining the room's call, so the issuer's own open invitations for
  # the room are handled and the DM peer rings for a new call.
  def after_issued!
    clear_open_invitations!
    invite_direct_participant
  end

  def authorization_payload
    { grant_id: id, room_name: room_name, identity: identity }
  end

  # Contract consumed by ActivityItems::Recorder. Only the other human in a
  # one-to-one DM can receive a huddle invitation from this grant.
  def activity_recipient_ids
    [ direct_huddle_recipient&.id ].compact
  end

  private
    # Joining late clears even a missed item: any open invitation for this
    # room and recipient is handled as soon as they obtain a grant here.
    def clear_open_invitations!
      open_invitations_for(user_id).find_each(&:mark_handled!)
    end

    # A huddle "starts" for a DM when a grant is issued while the other
    # participant is not in the call. Grants persist per session, so issuance
    # (created or reused) drives the ring and the dedup window guards it.
    def invite_direct_participant
      recipient = direct_huddle_recipient
      return unless recipient
      return if HuddleGrant.in_call.where(room_id: room_id, user_id: recipient.id).exists?
      return if recent_unhandled_invitation?(recipient)

      item = ActivityItems::Recorder.record!(recipient:, source: self, event_type: "huddle_started")
      return unless item

      unless item.previously_new_record?
        # Inbox identity is recipient + source, so a reused grant re-rings
        # through the same row. A stale invitation (handled, missed, or past
        # the window) is replaced with a fresh ring; a fresh one means a
        # concurrent issuance already rang and stands.
        return unless stale_invitation?(item)

        item.destroy!
        item = ActivityItems::Recorder.record!(recipient:, source: self, event_type: "huddle_started")
        return unless item
      end

      Huddle::PushInvitationJob.perform_later(item.id)
    end

    def direct_huddle_recipient
      return unless room.is_a?(Rooms::Direct)

      member_ids = room.memberships.pluck(:user_id)
      return unless member_ids.size == 2
      return unless User.active.without_bots.where(id: member_ids).count == 2

      other_id = (member_ids - [ user_id ]).first
      User.active.without_bots.find_by(id: other_id) if other_id
    end

    def recent_unhandled_invitation?(recipient)
      open_invitations_for(recipient.id)
        .where(activity_items: { created_at: INVITATION_DEDUP_WINDOW.ago.. })
        .exists?
    end

    def open_invitations_for(user_id)
      ActivityItem
        .where(user_id:, source_type: HuddleGrant.polymorphic_name, event_type: ActivityItem::HUDDLE_EVENT_TYPES, handled_at: nil)
        .joins("INNER JOIN huddle_grants AS invitation_grants ON invitation_grants.id = activity_items.source_id")
        .where(invitation_grants: { room_id: room_id })
    end

    def stale_invitation?(item)
      item.handled? || item.event_type != "huddle_started" || item.created_at < INVITATION_DEDUP_WINDOW.ago
    end
end
