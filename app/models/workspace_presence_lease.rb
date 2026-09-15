class WorkspacePresenceLease < ApplicationRecord
  TTL = 90.seconds

  belongs_to :session
  belongs_to :user

  scope :unexpired, -> { where(expires_at: Time.current..) }

  validates :connection_id, presence: true, uniqueness: true
  validates :expires_at, presence: true

  class << self
    def establish(user:, session:)
      prune
      return unless identity_valid?(user:, session:)

      create!(
        connection_id: SecureRandom.uuid,
        expires_at: TTL.from_now,
        session: session,
        user: user
      )
    end

    def online_user_ids(user_ids)
      prune

      unexpired.joins(:session, :user)
        .merge(User.active)
        .where(user_id: user_ids)
        .where("sessions.user_id = workspace_presence_leases.user_id")
        .distinct
        .pluck(:user_id)
    end

    def identity_valid?(user:, session:)
      user && session &&
        User.active.exists?(id: user.id) &&
        Session.exists?(id: session.id, user_id: user.id)
    end

    def prune(limit: 100)
      stale_ids = where(<<~SQL.squish, Time.current).limit(limit).pluck(:id)
        expires_at < ? OR NOT EXISTS (
          SELECT 1 FROM sessions
          WHERE sessions.id = workspace_presence_leases.session_id
            AND sessions.user_id = workspace_presence_leases.user_id
        )
      SQL

      where(id: stale_ids).delete_all
    end
  end

  def refresh
    if self.class.identity_valid?(user:, session:)
      update_column(:expires_at, TTL.from_now)
    else
      delete
      false
    end
  end
end
