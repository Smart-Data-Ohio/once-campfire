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

  after_update_commit :broadcast_voice_presence, if: :saved_change_to_revoked_at?

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

          stage_role = current_room.stage? ? current_membership.stage_role : nil

          existing = active.find_by(session_id: current_session.id, membership_id: current_membership.id)
          if existing && existing.stage_role == stage_role
            existing.update!(last_issued_at: Time.current)
            existing
          else
            existing&.revoke!
            create!(
              identity: "campfire-participant-#{SecureRandom.hex(32)}",
              room_name: Huddle.room_name(current_room.id),
              session_id: current_session.id,
              user_id: user.id,
              membership_id: current_membership.id,
              room_id: current_room.id,
              stage_role: stage_role,
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

    # Who is currently in the room's huddle: distinct users with an active
    # grant the gateway has seen within the in-call window, ordered by name.
    def participants_for(room)
      active.in_call.where(room_id: room.id).includes(:user).filter_map(&:user).uniq
        .sort_by { |user| user.name.downcase }
    end

    private
      def revoke_scope!(scope, create_cleanup: true)
        scope.find_each { |grant| grant.revoke!(create_cleanup: create_cleanup) }
      end
  end

  def authorized?
    return false if revoked?

    return false unless User.active.where.not(role: :bot).exists?(id: user_id) &&
      Session.exists?(id: session_id, user_id: user_id) &&
      Room.exists?(id: room_id)

    membership = Membership.find_by(id: membership_id, user_id: user_id, room_id: room_id)
    return false unless membership

    # A stage grant is only valid for the role it was issued for. The
    # gateway's per-second check revokes through here, so a demoted speaker
    # whose grant somehow survived the role-change revocation still loses the
    # call on the next check.
    !room.stage? || membership.stage_role == stage_role
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
      Stream.end_when_last_grant_revoked(self)
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

    first_seen = !in_call?
    update_columns(last_seen_at: Time.current)
    broadcast_voice_presence if first_seen
  end

  # Post-commit work for every issuance, created or reused: obtaining a grant
  # means joining the room's call, so the issuer's own open invitations for
  # the room are handled and the DM peer rings for a new call.
  def after_issued!
    clear_open_invitations!
    invite_direct_participant
    broadcast_voice_presence
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
    # (created or reused) drives the ring and the dedup window guards it: any
    # invitation or missed item from the last two minutes, handled or not,
    # keeps reconnects and rejoins silent.
    # Refresh the presence stacks in the room members' sidebars and in the
    # room header, for every room kind. The sidebar partial renders once and
    # the same HTML goes to each member's rooms stream, so a 200-member
    # channel does not render 200 times per join.
    def broadcast_voice_presence
      return unless Huddle.configured?

      huddle_room = Room.find_by(id: room_id)
      return unless huddle_room

      participants = self.class.participants_for(huddle_room)
      sidebar_html = ApplicationController.render(
        partial: "rooms/huddles/participants",
        locals: { room: huddle_room, placement: :sidebar, participants: participants }
      )

      huddle_room.memberships.includes(:user).find_each do |membership|
        broadcast_replace_to membership.user, :rooms,
          target: [ huddle_room, :sidebar_voice_participants ],
          html: sidebar_html
      end

      broadcast_replace_to huddle_room, :messages,
        target: [ huddle_room, :header_voice_participants ],
        partial: "rooms/huddles/participants",
        locals: { room: huddle_room, placement: :header, participants: participants }
    end

    def invite_direct_participant
      # Voice and stage channels are standing calls that members join at
      # will: nobody is ever invited, rung, or marked as missing the call.
      return if room.is_a?(Rooms::Voice) || room.is_a?(Rooms::Stage)

      recipient = direct_huddle_recipient
      return unless recipient
      return if HuddleGrant.in_call.where(room_id: room_id, user_id: recipient.id).exists?
      return if recent_invitation?(recipient)
      return if recent_grant_issuance?

      unless recipient.inbox_preferences.huddle_invitations
        broadcast_suppressed_invitation!(recipient)
        return
      end

      item = ActivityItems::Recorder.record!(recipient:, source: self, event_type: "huddle_started")
      return unless item
      return unless item.previously_new_record? || refresh_invitation!(item)

      Huddle::PushInvitationJob.perform_later(item.id)
    end

    # Inbox identity is recipient + source, so a reused grant re-rings through
    # the same row. The row is reset in place under a lock so the recipient's
    # existing links stay valid and two concurrent issuances cannot both ring;
    # a row another issuance refreshed inside the window stands as is.
    def refresh_invitation!(item)
      refreshed = false

      item.with_lock do
        if stale_invitation?(item)
          item.update!(event_type: "huddle_started", read_at: nil, handled_at: nil, created_at: Time.current)
          refreshed = true
        end
      end

      refreshed
    end

    def direct_huddle_recipient
      return unless room.is_a?(Rooms::Direct)

      member_ids = room.memberships.pluck(:user_id)
      return unless member_ids.size == 2
      return unless User.active.without_bots.where(id: member_ids).count == 2

      other_id = (member_ids - [ user_id ]).first
      return unless other_id

      recipient = User.active.without_bots.find_by(id: other_id)
      return unless recipient
      return if room.memberships.where(user_id: other_id, involvement: %w[ nothing invisible ]).exists?

      recipient
    end

    def recent_invitation?(recipient)
      invitations_for(recipient.id)
        .where(activity_items: { created_at: INVITATION_DEDUP_WINDOW.ago.. })
        .exists?
    end

    # The item query above cannot throttle the suppressed path, which never
    # creates an item, so a second grant for this room and starter inside
    # the same window also stays silent: rejoins and reconnects ring once.
    def recent_grant_issuance?
      previous_issue = last_issued_at_previously_was
      return true if previous_issue && previous_issue >= INVITATION_DEDUP_WINDOW.ago

      HuddleGrant.where(room_id: room_id, user_id: user_id)
        .where(created_at: INVITATION_DEDUP_WINDOW.ago..)
        .where.not(id: id)
        .exists?
    end

    def open_invitations_for(user_id)
      invitations_for(user_id).where(handled_at: nil)
    end

    def invitations_for(user_id)
      ActivityItem
        .where(user_id:, source_type: HuddleGrant.polymorphic_name, event_type: ActivityItem::HUDDLE_EVENT_TYPES)
        .joins("INNER JOIN huddle_grants AS invitation_grants ON invitation_grants.id = activity_items.source_id")
        .where(invitation_grants: { room_id: room_id })
    end

    def stale_invitation?(item)
      item.handled? || item.event_type != "huddle_started" || item.created_at < INVITATION_DEDUP_WINDOW.ago
    end

    # With huddle inbox items switched off, the call still rings in-app
    # through a banner payload without an item. Join and Dismiss skip the
    # read/handled round-trip that needs an item id. The payload carries no
    # nulls: empty paths and a zero id read as "no item" in the Stimulus
    # guards, where nil would arrive as the string "null" and NaN.
    def broadcast_suppressed_invitation!(recipient)
      return unless ActivityItem.active_human?(recipient)

      routes = Rails.application.routes.url_helpers
      ActionCable.server.broadcast ActivityChannel.stream_name_for(recipient.id), {
        activityItemId: 0,
        huddleInvitation: {
          activityItemId: 0,
          eventType: "huddle_started",
          state: "unread",
          roomId: room.id,
          roomName: suppressed_invitation_room_name(recipient),
          roomPath: routes.room_path(room),
          callerName: user&.name || "Someone",
          readPath: "",
          handledPath: ""
        }
      }
    end

    def suppressed_invitation_room_name(recipient)
      if room.direct?
        room.users.without(recipient).pluck(:name).to_sentence.presence || recipient.name
      else
        room.name
      end
    end
end
