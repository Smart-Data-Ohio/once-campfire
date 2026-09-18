module Google
  # Workspace "Sign in with Google" for ordinary members. Separate from
  # the Calendar/Drive connection flow (Google::Client), which requires
  # login and stays opt-in: this flow requests only "openid email
  # profile", never asks for offline access, and persists no OAuth
  # tokens -- only the verified subject in GoogleIdentity.
  module SignIn
    # Every deployment supplies its own Workspace domains. A missing or
    # empty allowlist disables Google sign-in.
    DOMAINS_ENV_VAR = "GOOGLE_SIGN_IN_DOMAINS"

    SCOPE = "openid email profile"
    AUTHORIZE_HOST = "accounts.google.com"
    JWKS_URI = "https://www.googleapis.com/oauth2/v3/certs"
    ISSUERS = %w[ https://accounts.google.com accounts.google.com ].freeze

    # How long a sign-in attempt stays usable between the POST that
    # starts it and Google's GET callback.
    FLOW_TTL = 10.minutes
    # Clock skew tolerated when checking token expiry.
    CLOCK_SKEW = 30.seconds

    # Fail-closed errors. Messages are safe to log: they never carry
    # tokens, codes, or raw claim values.
    class Error < StandardError; end

    # Google could not be reached or answered with garbage: the user
    # can retry or fall back to their password.
    class Unavailable < Error; end

    # The attempt itself is invalid (bad state, bad token, wrong
    # domain, ineligible account). Carries a stable reason for the
    # controller to map onto a user-facing message.
    class Rejected < Error
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("Google sign-in rejected (#{reason})")
      end
    end

    class << self
      def configured?
        Google::Client.configured? && allowed_domains.any?
      end

      # Normalized allowlist from GOOGLE_SIGN_IN_DOMAINS. Missing, empty,
      # or all-invalid configuration disables Google sign-in.
      def allowed_domains
        raw = ENV[DOMAINS_ENV_VAR]
        raw.to_s.split(",").map { |domain| domain.strip.downcase }
          .select { |domain| valid_domain?(domain) }.uniq
      end

      def authorize_url(redirect_uri:, state:, nonce:, challenge:)
        uri = URI::HTTPS.build(host: AUTHORIZE_HOST, path: "/o/oauth2/v2/auth")
        uri.query = URI.encode_www_form(
          client_id: Google::Client.client_id, redirect_uri:,
          response_type: "code", scope: SCOPE,
          state:, nonce:,
          code_challenge: challenge, code_challenge_method: "S256"
        )
        uri.to_s
      end

      def pkce_pair
        verifier = SecureRandom.urlsafe_base64(32)
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        [ verifier, challenge ]
      end

      # Exchange the callback code for tokens and return only the
      # id_token. Tokens are never logged or persisted.
      def exchange_code(code:, redirect_uri:, verifier:)
        response = Google::Client.post_token_form(
          client_id: Google::Client.client_id,
          client_secret: Google::Client.client_secret,
          code:, redirect_uri:,
          grant_type: "authorization_code", code_verifier: verifier
        )

        case response
        when Net::HTTPSuccess
          payload = JSON.parse(response.body.to_s)
          raise Unavailable, "Google sign-in returned an invalid response" unless payload.is_a?(Hash)

          id_token = payload["id_token"]
          raise Rejected, :bad_token unless id_token.is_a?(String) && id_token.present?
          id_token
        else
          raise Rejected, :denied
        end
      rescue *Google::Client::TRANSPORT_ERRORS => error
        raise Unavailable, "Google sign-in request failed (#{error.class})"
      end

      # Same-origin guard for the post-auth return URL the existing
      # auth helper stashed in the session. Returns a safe path or
      # nil when the stored value is missing or points elsewhere.
      def safe_return_path(stored_url, host:)
        return nil if stored_url.blank?

        uri = URI.parse(stored_url.to_s)
        target = uri.relative? ? uri.to_s : (uri.request_uri if uri.host == host)

        if target.is_a?(String) && target.start_with?("/") && !target.start_with?("//", "/\\")
          target
        end
      rescue URI::InvalidURIError
        nil
      end

      private
        def valid_domain?(domain)
          domain.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/)
        end
    end
  end
end
