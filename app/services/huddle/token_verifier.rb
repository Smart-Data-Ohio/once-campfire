class Huddle::TokenVerifier
  class Invalid < StandardError; end

  REQUIRED_CLAIMS = %w[ exp iss nbf sub video ].freeze
  REQUIRED_VIDEO_PERMISSIONS = %w[ roomJoin canPublish canSubscribe ].freeze
  FORBIDDEN_VIDEO_PERMISSIONS = %w[
    roomCreate roomList roomRecord roomAdmin canPublishData canUpdateOwnMetadata ingressAdmin hidden recorder agent
    canPublishTranscription
  ].freeze
  ALLOWED_VIDEO_CLAIMS = (
    %w[ room canPublishSources ] + REQUIRED_VIDEO_PERMISSIONS + FORBIDDEN_VIDEO_PERMISSIONS
  ).freeze

  def initialize(token)
    @token = token
  end

  def coordinates
    claims, = JWT.decode(
      @token,
      ENV.fetch("LIVEKIT_API_SECRET"),
      true,
      algorithm: "HS256",
      iss: ENV.fetch("LIVEKIT_API_KEY"),
      verify_iss: true,
      verify_expiration: true,
      verify_not_before: true,
      required_claims: REQUIRED_CLAIMS
    )

    identity = claims.fetch("sub")
    video_grant = claims.fetch("video")
    raise Invalid unless claims.fetch("exp").is_a?(Integer) && claims.fetch("nbf").is_a?(Integer)
    raise Invalid unless video_grant.is_a?(Hash)

    room_name = video_grant.fetch("room")

    raise Invalid unless identity.is_a?(String) && identity.present?
    raise Invalid unless room_name.is_a?(String) && room_name.present?
    raise Invalid unless (video_grant.keys - ALLOWED_VIDEO_CLAIMS).empty?
    raise Invalid unless REQUIRED_VIDEO_PERMISSIONS.all? { |permission| video_grant[permission] == true }
    raise Invalid unless FORBIDDEN_VIDEO_PERMISSIONS.none? { |permission| video_grant[permission] }

    publish_sources = video_grant["canPublishSources"]
    raise Invalid unless publish_sources.is_a?(Array) && publish_sources.all? { |source| source.is_a?(String) }
    raise Invalid unless publish_sources.sort == Huddle::PUBLISH_SOURCES.sort

    { identity: identity, room_name: room_name }
  rescue JWT::DecodeError, KeyError, TypeError, ArgumentError, NoMethodError
    raise Invalid
  end
end
