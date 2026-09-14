require "jwt"
require "openssl"

class Huddle
  TOKEN_TTL = 2.minutes
  PUBLISH_SOURCES = %w[ microphone screen_share screen_share_audio ].freeze

  class << self
    def configured?
      ENV.values_at("LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET").all?(&:present?)
    end

    def room_name(room_id)
      opaque_identifier("room", room_id)
    end

    def identity(session_id)
      opaque_identifier("participant", session_id)
    end

    def participant_revocations(room_ids:, session_ids:)
      return [] unless configured?

      room_ids.product(session_ids).map { |room_id, session_id| [ room_name(room_id), identity(session_id) ] }
    end

    def enqueue_participant_revocations(revocations)
      Array(revocations).each do |room_name, identity|
        safely_enqueue { Huddle::RevokeParticipantJob.perform_later(room_name, identity) }
      end
    end

    def enqueue_room_deletion(room_name)
      safely_enqueue { Huddle::DeleteRoomJob.perform_later(room_name) } if room_name.present?
    end

    private
      def opaque_identifier(kind, record_id)
        digest = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("LIVEKIT_API_SECRET"), "campfire-huddle:#{kind}:#{record_id}")
        "campfire-#{kind}-#{digest}"
      end

      def safely_enqueue
        yield
      rescue => error
        Rails.logger.warn "Could not enqueue huddle cleanup: #{error.class}"
      end
  end

  attr_reader :room, :session, :user

  def initialize(room:, user:, session:)
    @room = room
    @user = user
    @session = session
  end

  def url
    ENV.fetch("LIVEKIT_URL")
  end

  def room_name
    self.class.room_name(room.id)
  end

  def identity
    self.class.identity(session.id)
  end

  def token
    now = Time.current.to_i

    JWT.encode({
      exp: now + TOKEN_TTL.to_i,
      iat: now,
      iss: api_key,
      jti: SecureRandom.uuid,
      name: user.name,
      nbf: now - 5,
      sub: identity,
      video: {
        room: room_name,
        roomJoin: true,
        roomCreate: false,
        roomList: false,
        roomAdmin: false,
        roomRecord: false,
        canPublish: true,
        canPublishData: false,
        canPublishSources: PUBLISH_SOURCES,
        canSubscribe: true
      }
    }, api_secret, "HS256")
  end

  private
    def api_key
      ENV.fetch("LIVEKIT_API_KEY")
    end

    def api_secret
      ENV.fetch("LIVEKIT_API_SECRET")
    end
end
