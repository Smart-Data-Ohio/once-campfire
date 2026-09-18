module GoogleSignInTestHelper
  extend ActiveSupport::Concern

  GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
  # Token endpoint constant comes from GoogleCalendarTestHelper; tests using
  # this helper include both.
  SIGN_IN_KID = "signin-test-key"

  class << self
    # Memoized per process: generating RSA keys per test would be slow.
    def sign_in_key
      @sign_in_key ||= OpenSSL::PKey::RSA.new(2048)
    end

    def sign_in_attacker_key
      @sign_in_attacker_key ||= OpenSSL::PKey::RSA.new(2048)
    end
  end

  included do
    setup :configure_google_sign_in_for_test
    teardown :restore_google_sign_in_after_test
  end

  def sign_in_key
    GoogleSignInTestHelper.sign_in_key
  end

  def sign_in_attacker_key
    GoogleSignInTestHelper.sign_in_attacker_key
  end

  def stub_google_jwks(key: sign_in_key, kid: SIGN_IN_KID)
    jwk = {
      "kty" => "RSA", "kid" => kid, "use" => "sig", "alg" => "RS256",
      "n" => Base64.urlsafe_encode64(key.n.to_s(2), padding: false),
      "e" => Base64.urlsafe_encode64(key.e.to_s(2), padding: false)
    }
    stub_request(:get, GOOGLE_JWKS_URL).to_return(
      status: 200,
      body: { "keys" => [ jwk ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  # Real-signed OIDC id_token using the test key. Defaults to the
  # nonce of the flow started most recently in this test.
  def sign_in_id_token(email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice",
      aud: "test-client-id", azp: :absent, iss: "https://accounts.google.com", nonce: :current,
      exp: 1.hour.from_now.to_i, email_verified: true, key: sign_in_key, kid: SIGN_IN_KID, **extra_claims)
    nonce = @last_sign_in_nonce if nonce == :current
    raise "start the Google sign-in flow before building an id_token" if nonce == :current

    payload = { iss:, aud:, sub:, email:, email_verified:, hd:, nonce:, exp:, iat: Time.current.to_i }
    payload[:azp] = azp unless azp == :absent
    payload.merge!(extra_claims)
    payload.compact!
    JWT.encode(payload, key, "RS256", { kid:, typ: "JWT" })
  end

  def stub_sign_in_code_exchange(id_token: sign_in_id_token)
    body = { access_token: "signin-access-token", expires_in: 3600, token_type: "Bearer", id_token: }
    body.compact!
    stub_request(:post, GoogleCalendarTestHelper::GOOGLE_TOKEN_URL).to_return(
      status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  # Start the flow and return the state Google would echo back. Remembers
  # the flow nonce so sign_in_id_token can sign for it by default.
  def start_google_sign_in(return_to: nil)
    get return_to if return_to
    post session_google_path
    assert_response :redirect
    query = Rack::Utils.parse_query(URI(response.location).query)
    @last_sign_in_nonce = query["nonce"]
    query["state"]
  end

  def complete_google_sign_in(state:, code: "auth-code", stubs: true, **token_options)
    if stubs
      stub_google_jwks
      stub_sign_in_code_exchange(id_token: sign_in_id_token(**token_options))
    end
    get session_google_callback_path, params: { state:, code: }.compact
  end

  private
    def configure_google_sign_in_for_test
      @google_sign_in_env_before_test = [ ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"], ENV["GOOGLE_SIGN_IN_DOMAINS"] ]
      ENV["GOOGLE_CLIENT_ID"] = "test-client-id"
      ENV["GOOGLE_CLIENT_SECRET"] = "test-client-secret"
      ENV["GOOGLE_SIGN_IN_DOMAINS"] = "smartdata.net,cnbssoftware.com"
      Google::SignIn::KeyStore.clear!
    end

    def restore_google_sign_in_after_test
      ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"], ENV["GOOGLE_SIGN_IN_DOMAINS"] = @google_sign_in_env_before_test
      Google::SignIn::KeyStore.clear!
    end
end
