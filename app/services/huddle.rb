require "jwt"
require "openssl"
require "uri"

class Huddle
  TOKEN_TTL = 2.minutes
  PUBLISH_SOURCES = %w[ microphone screen_share screen_share_audio camera ].freeze
  REQUIRED_ENVIRONMENT = %w[
    LIVEKIT_URL LIVEKIT_INTERNAL_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_GATEWAY_SECRET
  ].freeze

  class << self
    def configured?
      ENV.values_at(*REQUIRED_ENVIRONMENT).all?(&:present?) && gateway_separates_livekit?
    end

    def token_signing_configured?
      ENV.values_at("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET").all?(&:present?)
    end

    def livekit_admin_configured?
      ENV.values_at("LIVEKIT_INTERNAL_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET").all?(&:present?)
    end

    def room_name(room_id)
      opaque_identifier("room", room_id)
    end

    def participant_video_grant(room_name, publish: true)
      {
        room: room_name,
        roomJoin: true,
        roomCreate: false,
        roomList: false,
        roomAdmin: false,
        roomRecord: false,
        canPublish: publish,
        canPublishData: false,
        canPublishSources: publish ? PUBLISH_SOURCES : [],
        canSubscribe: true
      }
    end

    private
      def gateway_separates_livekit?
        public_endpoint = endpoint_address(ENV.fetch("LIVEKIT_URL"))
        internal_endpoint = endpoint_address(ENV.fetch("LIVEKIT_INTERNAL_URL"))

        public_endpoint != internal_endpoint
      rescue URI::InvalidURIError
        false
      end

      def endpoint_address(value)
        uri = URI.parse(value)
        default_port = default_port(uri.scheme)
        raise URI::InvalidURIError unless uri.host.present?

        [ uri.host.downcase, uri.port || default_port ]
      end

      def default_port(scheme)
        { "http" => 80, "ws" => 80, "https" => 443, "wss" => 443 }.fetch(scheme)
      rescue KeyError
        raise URI::InvalidURIError
      end

      def opaque_identifier(kind, record_id)
        digest = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("LIVEKIT_API_SECRET"), "campfire-huddle:#{kind}:#{record_id}")
        "campfire-#{kind}-#{digest}"
      end
  end

  attr_reader :grant, :room, :session, :user

  def initialize(room:, user:, session:, membership:)
    @room = room
    @user = user
    @session = session
    @grant = HuddleGrant.issue!(session: session, membership: membership)
  end

  def url
    ENV.fetch("LIVEKIT_URL")
  end

  def room_name
    grant.room_name
  end

  def identity
    grant.identity
  end

  def grant_id
    grant.id
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
      video: self.class.participant_video_grant(room_name, publish: can_publish?)
    }, api_secret, "HS256")
  end

  private
    # Only stage listeners are publish-restricted: hosts and speakers publish
    # like any other huddle participant, and every non-stage room is unchanged.
    # The grant's role was read under lock at issuance, and a stage grant
    # without a recorded role publishes nothing.
    def can_publish?
      return true unless room.stage?

      grant.stage_role.in?(%w[ host speaker ])
    end

    def api_key
      ENV.fetch("LIVEKIT_API_KEY")
    end

    def api_secret
      ENV.fetch("LIVEKIT_API_SECRET")
    end
end
