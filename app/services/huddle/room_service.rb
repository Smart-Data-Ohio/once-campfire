require "json"
require "net/http"
require "uri"

class Huddle::RoomService
  OPEN_TIMEOUT = 3.seconds
  READ_TIMEOUT = 5.seconds
  TOKEN_TTL = 1.minute

  def remove_participant(room_name:, identity:)
    post "RemoveParticipant", { room: room_name, identity: identity }, roomAdmin: true, room: room_name
  end

  def delete_room(room_name:)
    post "DeleteRoom", { room: room_name }, roomCreate: true
  end

  private
    def post(action, body, grant)
      uri = endpoint_uri(action)
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{admin_token(grant)}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end

      return if response.is_a?(Net::HTTPSuccess) || response.code.to_i == 404

      raise Huddle::ServerError.new(status: response.code.to_i)
    rescue Huddle::ServerError
      raise
    rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, URI::InvalidURIError => error
      raise Huddle::ServerError.new(code: error.class.name)
    end

    def endpoint_uri(action)
      source = URI.parse(ENV.fetch("LIVEKIT_URL"))
      scheme = { "ws" => "http", "wss" => "https", "http" => "http", "https" => "https" }.fetch(source.scheme)
      raise URI::InvalidURIError, "LiveKit URL must include a host" if source.host.blank?

      uri_class = scheme == "https" ? URI::HTTPS : URI::HTTP
      uri_class.build(
        host: source.host,
        port: source.port,
        path: "#{source.path.to_s.chomp("/")}/twirp/livekit.RoomService/#{action}"
      )
    rescue KeyError
      raise URI::InvalidURIError, "Unsupported LiveKit URL scheme"
    end

    def admin_token(grant)
      now = Time.current.to_i

      JWT.encode({
        exp: now + TOKEN_TTL.to_i,
        iat: now,
        iss: ENV.fetch("LIVEKIT_API_KEY"),
        jti: SecureRandom.uuid,
        nbf: now - 5,
        video: grant
      }, ENV.fetch("LIVEKIT_API_SECRET"), "HS256")
    end
end
