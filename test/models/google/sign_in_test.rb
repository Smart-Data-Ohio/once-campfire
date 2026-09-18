require "test_helper"

class Google::SignInTest < ActiveSupport::TestCase
  include GoogleSignInTestHelper
  include GoogleCalendarTestHelper

  test "missing domain configuration disables sign-in without company defaults" do
    ENV.delete("GOOGLE_SIGN_IN_DOMAINS")

    assert_empty Google::SignIn.allowed_domains
    assert_not Google::SignIn.configured?
  end

  test "allowed_domains honors explicit configuration" do
    ENV["GOOGLE_SIGN_IN_DOMAINS"] = "Example.COM, other.test "

    assert_equal %w[ example.com other.test ], Google::SignIn.allowed_domains
  end

  test "allowed_domains drops invalid entries" do
    ENV["GOOGLE_SIGN_IN_DOMAINS"] = "smartdata.net, not a domain, , evil"

    assert_equal %w[ smartdata.net ], Google::SignIn.allowed_domains
  end

  test "explicitly empty domains disables sign-in" do
    ENV["GOOGLE_SIGN_IN_DOMAINS"] = ""

    assert_empty Google::SignIn.allowed_domains
    assert_not Google::SignIn.configured?
  end

  test "configured? requires client credentials and domains" do
    assert Google::SignIn.configured?

    disconnect_google_env!

    assert_not Google::SignIn.configured?
  end

  test "authorize_url requests identity-only scopes with nonce and PKCE" do
    url = Google::SignIn.authorize_url(
      redirect_uri: "http://test.host/session/google/callback",
      state: "signed-state", nonce: "nonce", challenge: "challenge"
    )
    query = Rack::Utils.parse_query(URI(url).query)

    assert_equal "https", URI(url).scheme
    assert_equal "accounts.google.com", URI(url).host
    assert_equal "test-client-id", query["client_id"]
    assert_equal "code", query["response_type"]
    assert_equal "openid email profile", query["scope"]
    assert_equal "signed-state", query["state"]
    assert_equal "nonce", query["nonce"]
    assert_equal "challenge", query["code_challenge"]
    assert_equal "S256", query["code_challenge_method"]
  end

  test "pkce_pair produces a matching verifier and challenge" do
    verifier, challenge = Google::SignIn.pkce_pair

    assert_operator verifier.length, :>=, 43
    assert_equal challenge, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
  end

  test "safe_return_path keeps relative paths and same-host URLs" do
    assert_equal "/rooms/1", Google::SignIn.safe_return_path("/rooms/1", host: "example.test")
    assert_equal "/rooms/1?page=2", Google::SignIn.safe_return_path("/rooms/1?page=2", host: "example.test")
    assert_equal "/rooms/1", Google::SignIn.safe_return_path("http://example.test/rooms/1", host: "example.test")
  end

  test "safe_return_path rejects off-origin and malformed values" do
    assert_nil Google::SignIn.safe_return_path(nil, host: "example.test")
    assert_nil Google::SignIn.safe_return_path("", host: "example.test")
    assert_nil Google::SignIn.safe_return_path("https://evil.test/rooms/1", host: "example.test")
    assert_nil Google::SignIn.safe_return_path("//evil.test/rooms/1", host: "example.test")
    assert_nil Google::SignIn.safe_return_path("/\\evil.test", host: "example.test")
    assert_nil Google::SignIn.safe_return_path("javascript:alert(1)", host: "example.test")
    assert_nil Google::SignIn.safe_return_path("http://example.test.evil.test/", host: "example.test")
  end

  test "exchange_code returns only the id_token" do
    stub_sign_in_code_exchange(id_token: "the-id-token")

    assert_equal "the-id-token",
      Google::SignIn.exchange_code(code: "code", redirect_uri: "http://test.host/callback", verifier: "verifier")
    assert_requested :post, GOOGLE_TOKEN_URL, body: /code_verifier=verifier/
  end

  test "exchange_code raises Rejected on denial and Unavailable on outage" do
    stub_request(:post, GOOGLE_TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    error = assert_raises(Google::SignIn::Rejected) do
      Google::SignIn.exchange_code(code: "bad", redirect_uri: "http://test.host/callback", verifier: "v")
    end
    assert_equal :denied, error.reason

    WebMock.reset!
    stub_request(:post, GOOGLE_TOKEN_URL).to_timeout

    assert_raises(Google::SignIn::Unavailable) do
      Google::SignIn.exchange_code(code: "code", redirect_uri: "http://test.host/callback", verifier: "v")
    end
  end
end
