class Session < ApplicationRecord
  ACTIVITY_REFRESH_RATE = 1.hour

  has_secure_token

  belongs_to :user

  before_destroy :capture_huddle_revocations
  after_destroy_commit :revoke_huddle_participants
  before_create { self.last_active_at ||= Time.now }

  def self.start!(user_agent:, ip_address:)
    create! user_agent: user_agent, ip_address: ip_address
  end

  def resume(user_agent:, ip_address:)
    if last_active_at.before?(ACTIVITY_REFRESH_RATE.ago)
      update! user_agent: user_agent, ip_address: ip_address, last_active_at: Time.now
    end
  end

  private
    def capture_huddle_revocations
      @huddle_revocations = Huddle.participant_revocations(room_ids: user.room_ids, session_ids: [ id ])
    end

    def revoke_huddle_participants
      Huddle.enqueue_participant_revocations(@huddle_revocations)
    end
end
