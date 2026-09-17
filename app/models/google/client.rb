require "net/http"
require "base64"

module Google
  # Minimal Google OAuth + Calendar client over Net::HTTP. All network access
  # for Google Calendar publishing goes through here so tests can stub it
  # with WebMock. Never logs tokens; error messages carry only HTTP statuses
  # and Google's error codes.
  class Client
    AUTHORIZE_HOST = "accounts.google.com"
    TOKEN_HOST = "oauth2.googleapis.com"
    API_HOST = "www.googleapis.com"
    TIMEOUT = 10
    SCOPE = "openid email https://www.googleapis.com/auth/calendar.events"
    ID_TOKEN_ISSUERS = %w[ https://accounts.google.com accounts.google.com ].freeze

    class Error < StandardError; end
    class Unauthorized < Error; end
    class NotFound < Error; end
    class Conflict < Error; end

    class << self
      def configured?
        client_id.present? && client_secret.present?
      end

      def client_id
        ENV["GOOGLE_CLIENT_ID"].presence
      end

      def client_secret
        ENV["GOOGLE_CLIENT_SECRET"].presence
      end

      def authorize_url(redirect_uri:, state:)
        uri = URI::HTTPS.build(host: AUTHORIZE_HOST, path: "/o/oauth2/v2/auth")
        uri.query = URI.encode_www_form(
          client_id: client_id, redirect_uri:, response_type: "code",
          scope: SCOPE, access_type: "offline", prompt: "consent", state:
        )
        uri.to_s
      end

      # Exchange an authorization code for tokens. Returns the parsed token
      # response (access_token, refresh_token, expires_in).
      def exchange_code(code:, redirect_uri:)
        response = post_token_form(
          client_id:, client_secret:, code:, redirect_uri:,
          grant_type: "authorization_code"
        )

        case response
        when Net::HTTPSuccess
          JSON.parse(response.body)
        else
          raise Error, "Google token exchange failed (#{response.code} #{token_error_code(response)})".squish
        end
      end

      # Shared token-endpoint POST for the code exchange and refreshes.
      def post_token_form(params)
        uri = URI::HTTPS.build(host: TOKEN_HOST, path: "/token")
        Net::HTTP.start(uri.host, uri.port, use_ssl: true,
            open_timeout: TIMEOUT, read_timeout: TIMEOUT, write_timeout: TIMEOUT) do |http|
          http.post(uri.request_uri, URI.encode_www_form(params),
            "Content-Type" => "application/x-www-form-urlencoded")
        end
      end

      def token_error_code(response)
        JSON.parse(response.body.to_s)["error"]
      rescue JSON::ParserError
        nil
      end

      # The account email comes from the id_token returned by the token
      # endpoint, so connecting needs no extra API call. The token arrives
      # directly from Google over TLS, so the payload is trusted after
      # checking iss/aud/exp; no signature check is needed.
      def email_from_id_token(id_token)
        segments = id_token.to_s.split(".")
        raise Error, "Google rejected the connection" unless segments.size == 3

        payload = JSON.parse(Base64.urlsafe_decode64(pad_base64url(segments[1])))
        raise Error, "Google rejected the connection" unless valid_id_token_payload?(payload)

        payload["email"]
      rescue ArgumentError, JSON::ParserError
        raise Error, "Google rejected the connection"
      end

      private
        def pad_base64url(segment)
          segment + "=" * (-segment.length % 4)
        end

        def valid_id_token_payload?(payload)
          payload.is_a?(Hash) &&
            payload["iss"].in?(ID_TOKEN_ISSUERS) &&
            payload["aud"] == client_id &&
            payload["exp"].to_i > Time.current.to_i &&
            payload["email"].present?
        end
    end

    def initialize(account)
      @account = account
    end

    def insert_event(payload)
      api_request(:post, "/calendar/v3/calendars/primary/events", payload)
    end

    def update_event(google_event_id, payload)
      api_request(:put, "/calendar/v3/calendars/primary/events/#{google_event_id}", payload)
    end

    def delete_event(google_event_id)
      api_request(:delete, "/calendar/v3/calendars/primary/events/#{google_event_id}")
    end

    def refresh_access_token!
      response = self.class.post_token_form(
        client_id: self.class.client_id, client_secret: self.class.client_secret,
        refresh_token: @account.refresh_token, grant_type: "refresh_token"
      )

      case response
      when Net::HTTPSuccess
        tokens = JSON.parse(response.body)
        @account.update!(
          access_token: tokens["access_token"],
          access_token_expires_at: Time.current + tokens["expires_in"].to_i.seconds
        )
      else
        if response.code == "400" && self.class.token_error_code(response) == "invalid_grant"
          @account.mark_disconnected!("Google rejected the connection")
          raise Unauthorized, "Google rejected the refresh token"
        end
        raise Error, "Google token refresh failed (#{response.code})"
      end
    end

    private
      def api_request(method, path, payload = nil)
        refresh_access_token! if @account.access_token_expired?

        response = send_api_request(method, path, payload)
        if response.code == "401"
          refresh_access_token!
          response = send_api_request(method, path, payload)
        end

        case response
        when Net::HTTPSuccess
          response.body.present? ? JSON.parse(response.body) : true
        when Net::HTTPUnauthorized
          raise Unauthorized, "Google rejected the request (401)"
        when Net::HTTPNotFound
          raise NotFound, "Google calendar entry not found"
        when Net::HTTPConflict
          raise Conflict, "Google calendar entry already exists"
        else
          raise Error, "Google Calendar request failed (#{response.code})"
        end
      end

      def send_api_request(method, path, payload)
        uri = URI::HTTPS.build(host: API_HOST, path:)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true,
            open_timeout: TIMEOUT, read_timeout: TIMEOUT, write_timeout: TIMEOUT) do |http|
          if method.in?(%i[ get delete ])
            http.send(method, uri.request_uri, headers)
          else
            http.send(method, uri.request_uri, payload&.to_json, headers)
          end
        end
      end

      def headers
        {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{@account.access_token}"
        }
      end
  end
end
