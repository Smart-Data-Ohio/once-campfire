class HuddleGrant < ApplicationRecord
  class Ineligible < StandardError; end

  belongs_to :session, optional: true
  belongs_to :user, optional: true
  belongs_to :membership, optional: true
  belongs_to :room, optional: true

  has_many :huddle_cleanups, dependent: :restrict_with_exception

  scope :active, -> { where(revoked_at: nil) }

  validates :identity, :room_name, presence: true
  validates :identity, uniqueness: true

  class << self
    def issue!(session:, membership:)
      attempts = 0

      begin
        transaction do
          user = User.active.where.not(role: :bot).lock.find_by(id: session.user_id)
          current_session = Session.lock.find_by(id: session.id, user_id: user&.id)
          current_membership = Membership.lock.find_by(id: membership.id, user_id: user&.id, room_id: membership.room_id)
          current_room = Room.lock.find_by(id: current_membership&.room_id)

          raise Ineligible unless user && current_session && current_membership && current_room

          revoke_scope! active.where(session_id: current_session.id, room_id: current_room.id)
            .where.not(membership_id: current_membership.id)

          active.find_by(session_id: current_session.id, membership_id: current_membership.id) || create!(
            identity: "campfire-participant-#{SecureRandom.hex(32)}",
            room_name: Huddle.room_name(current_room.id),
            session_id: current_session.id,
            user_id: user.id,
            membership_id: current_membership.id,
            room_id: current_room.id
          )
        end
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

  def authorization_payload
    { grant_id: id, room_name: room_name, identity: identity }
  end
end
