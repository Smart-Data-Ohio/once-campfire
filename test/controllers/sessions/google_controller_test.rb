require "test_helper"

class Sessions::GoogleControllerTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include GoogleCalendarTestHelper

  test "login page offers Google sign-in with the mark, domains, and password note" do
    get new_session_url

    assert_response :success
    assert_select "form[action='#{session_google_path}'][data-turbo='false']", count: 1
    assert_select "form[action='#{session_google_path}'] button", text: /Sign in with Google/
    assert_select "form[action='#{session_google_path}'] svg path[fill='#EA4335']", count: 1
    assert_select "p", text: /@smartdata\.net/
    assert_select "p", text: /@cnbssoftware\.com/
    assert_select "p", text: /Other email addresses can sign in with email and password\./
    # The existing form stays intact.
    assert_select "form[action='#{session_url}'] input[name='email_address']", count: 1
    assert_select "form[action='#{session_url}'] input[name='password']", count: 1
  end

  test "login page hides the Google button when credentials are missing" do
    disconnect_google_env!

    get new_session_url

    assert_response :success
    assert_select "form[action='#{session_google_path}']", count: 0
    assert_select "form[action='#{session_url}']", count: 1
  end

  test "login page hides the Google button when domains are explicitly empty" do
    ENV["GOOGLE_SIGN_IN_DOMAINS"] = ""

    get new_session_url

    assert_response :success
    assert_select "form[action='#{session_google_path}']", count: 0
  end

  test "start redirects to Google with identity-only scope, nonce, and PKCE" do
    post session_google_path

    assert_response :redirect
    uri = URI(response.location)
    query = Rack::Utils.parse_query(uri.query)
    assert_equal "accounts.google.com", uri.host
    assert_equal "test-client-id", query["client_id"]
    assert_equal session_google_callback_url, query["redirect_uri"]
    assert_equal "code", query["response_type"]
    assert_equal "openid email profile", query["scope"]
    assert_predicate query["state"], :present?
    assert_predicate query["nonce"], :present?
    assert_predicate query["code_challenge"], :present?
    assert_equal "S256", query["code_challenge_method"]
    assert_not_includes query.keys, "access_type"
    assert_not_includes query.keys, "prompt"
    assert_not_includes query.keys, "hd"
    assert_not_includes query.keys, "include_granted_scopes"
  end

  test "start requires CSRF protection" do
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_raises(ActionController::InvalidAuthenticityToken) do
      post session_google_path
    end
  ensure
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  test "start and callback 404 when Google credentials are missing" do
    disconnect_google_env!

    post session_google_path
    assert_response :not_found

    get session_google_callback_path, params: { state: "x", code: "y" }
    assert_response :not_found
  end

  test "start and callback 404 when sign-in domains are explicitly empty" do
    ENV["GOOGLE_SIGN_IN_DOMAINS"] = ""

    post session_google_path
    assert_response :not_found

    get session_google_callback_path, params: { state: "x", code: "y" }
    assert_response :not_found
  end

  test "signed-in users are sent home instead of starting or finishing Google sign-in" do
    sign_in :david

    post session_google_path
    assert_redirected_to root_url

    get session_google_callback_path, params: { state: "x", code: "y" }
    assert_redirected_to root_url
  end

  test "first-run setup cannot be bypassed through Google sign-in" do
    Account.destroy_all
    User.destroy_all

    post session_google_path
    assert_redirected_to first_run_url

    get session_google_callback_path, params: { state: "x", code: "y" }
    assert_redirected_to first_run_url
  end

  test "new smartdata.net user is auto-provisioned as an ordinary member" do
    state = start_google_sign_in

    assert_difference -> { User.count }, +1 do
      assert_difference -> { Session.count }, +1 do
        complete_google_sign_in(state:, email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice")
      end
    end

    assert_redirected_to root_url
    assert parsed_cookies.signed[:session_token]

    user = User.find_by!(email_address: "alice@smartdata.net")
    assert user.member?
    assert user.active?
    assert_nil user.password_digest
    assert_nil user.agent
    assert_equal "google-sub-alice", user.google_identity.subject
    assert_equal "alice@smartdata.net", user.google_identity.email
    assert_equal Rooms::Open.pluck(:id).sort, user.rooms.where(type: "Rooms::Open").pluck(:id).sort
    assert_empty user.rooms.where(type: "Rooms::Closed")
  end

  test "new cnbssoftware.com user is auto-provisioned as an ordinary member" do
    state = start_google_sign_in

    complete_google_sign_in(state:, email: "bob@cnbssoftware.com", hd: "cnbssoftware.com", sub: "google-sub-bob")

    assert_redirected_to root_url
    user = User.find_by!(email_address: "bob@cnbssoftware.com")
    assert user.member?
    assert user.active?
    assert_nil user.password_digest
    assert_equal "google-sub-bob", user.google_identity.subject
  end

  test "existing account links by verified email, preserving id, history, role, and password" do
    user = User.create!(name: "Riel", email_address: "riel@smartdata.net", password: "secret123456", role: :administrator)
    message = Message.create!(room: rooms(:pets), creator: user, body: "history stays")

    state = start_google_sign_in

    assert_no_difference -> { User.count } do
      complete_google_sign_in(state:, email: "Riel@SmartData.net", hd: "smartdata.net", sub: "google-sub-riel")
    end

    assert_redirected_to root_url
    assert_equal user.id, GoogleIdentity.find_by!(subject: "google-sub-riel").user_id
    assert_equal "administrator", user.reload.role
    assert_equal "history stays", message.reload.body.to_plain_text
    assert_equal user.id, message.creator_id

    # The password still works after linking.
    delete session_url
    post session_url, params: { email_address: "riel@smartdata.net", password: "secret123456" }
    assert_redirected_to root_url
  end

  test "subsequent logins resolve the immutable subject across email changes" do
    state = start_google_sign_in
    complete_google_sign_in(state:, email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice")
    user = User.find_by!(email_address: "alice@smartdata.net")
    delete session_url

    renamed_state = start_google_sign_in

    assert_no_difference -> { User.count } do
      complete_google_sign_in(state: renamed_state, email: "asmith@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice")
    end

    assert_redirected_to root_url
    assert_equal user.id, user.reload.google_identity.user_id
    assert_equal "asmith@smartdata.net", user.google_identity.email
  end

  test "post-auth return destination survives the Google round trip" do
    # Visiting a protected page stashes the return destination, then the
    # Google round trip completes and lands back on that page.
    state = start_google_sign_in(return_to: room_url(rooms(:pets)))

    complete_google_sign_in(state:, email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice")

    assert_redirected_to room_url(rooms(:pets))
  end

  test "external Google account is rejected while password sign-in still works" do
    state = start_google_sign_in

    assert_no_difference -> { User.count } do
      assert_no_difference -> { Session.count } do
        complete_google_sign_in(state:, email: "mallory@gmail.com", hd: "gmail.com", sub: "google-sub-mallory")
      end
    end

    assert_redirected_to new_session_url
    follow_redirect!
    assert_select ".flash", text: /only available for @smartdata\.net and @cnbssoftware\.com/

    # Global access is unrestricted: the form still works for everyone.
    post session_url, params: { email_address: "david@37signals.com", password: "secret123456" }
    assert_redirected_to root_url
  end

  test "missing hd is rejected: the email suffix alone proves nothing" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state:, email: "alice@smartdata.net", hd: nil, sub: "google-sub-alice")
    end

    assert_redirected_to new_session_url
  end

  test "spoofed hd with an external email domain is rejected" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state:, email: "mallory@evil.test", hd: "smartdata.net", sub: "google-sub-mallory")
    end

    assert_redirected_to new_session_url
    follow_redirect!
    assert_select ".flash", text: /only available for/
  end

  test "allowed email with an external hd is rejected" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state:, email: "alice@smartdata.net", hd: "evil.test", sub: "google-sub-alice")
    end

    assert_redirected_to new_session_url
  end

  test "Google-only user cannot sign in with a password" do
    state = start_google_sign_in
    complete_google_sign_in(state:, email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice")
    delete session_url

    post session_url, params: { email_address: "alice@smartdata.net", password: "anything" }

    assert_response :unauthorized
  end

  test "deactivated user with a retained identity is rejected, never revived" do
    state = start_google_sign_in
    complete_google_sign_in(state:, email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice")
    user = User.find_by!(email_address: "alice@smartdata.net")
    user.deactivate
    delete session_url

    relogin_state = start_google_sign_in

    assert_no_difference -> { Session.count } do
      complete_google_sign_in(state: relogin_state, email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice")
    end

    assert_redirected_to new_session_url
    assert user.reload.deactivated?
    assert_equal "google-sub-alice", user.google_identity.subject
  end

  test "deactivated predecessor without an identity is not recreated" do
    user = User.create!(name: "Gone", email_address: "gone@smartdata.net", password: "secret123456")
    user.deactivate
    assert_not_equal "gone@smartdata.net", user.reload.email_address

    state = start_google_sign_in

    assert_no_difference -> { User.count } do
      assert_no_difference -> { Session.count } do
        complete_google_sign_in(state:, email: "gone@smartdata.net", hd: "smartdata.net", sub: "google-sub-gone")
      end
    end

    assert_redirected_to new_session_url
    assert_not GoogleIdentity.exists?(subject: "google-sub-gone")
  end

  test "banned user is rejected" do
    user = User.create!(name: "Banned", email_address: "banned@smartdata.net", password: "secret123456")
    user.ban

    state = start_google_sign_in

    assert_no_difference -> { Session.count } do
      complete_google_sign_in(state:, email: "banned@smartdata.net", hd: "smartdata.net", sub: "google-sub-banned")
    end

    assert_redirected_to new_session_url
  end

  test "bot user is rejected" do
    User.create_bot!(name: "Botty", email_address: "botty@smartdata.net")

    state = start_google_sign_in

    assert_no_difference -> { Session.count } do
      complete_google_sign_in(state:, email: "botty@smartdata.net", hd: "smartdata.net", sub: "google-sub-botty")
    end

    assert_redirected_to new_session_url
  end

  test "agent user is rejected" do
    agent_user = User.create!(name: "Agent", email_address: "agent@smartdata.net", password: "secret123456")
    Agent.create!(user: agent_user, owner: users(:david), kind: "workspace")

    state = start_google_sign_in

    assert_no_difference -> { Session.count } do
      complete_google_sign_in(state:, email: "agent@smartdata.net", hd: "smartdata.net", sub: "google-sub-agent")
    end

    assert_redirected_to new_session_url
  end

  test "ambiguous duplicate emails are rejected" do
    User.create!(name: "Case One", email_address: "Case@smartdata.net", password: "secret123456")
    User.create!(name: "Case Two", email_address: "case@smartdata.net", password: "secret123456")

    state = start_google_sign_in

    assert_no_difference -> { Session.count } do
      complete_google_sign_in(state:, email: "case@smartdata.net", hd: "smartdata.net", sub: "google-sub-case")
    end

    assert_redirected_to new_session_url
    follow_redirect!
    assert_select ".flash", text: /could not pick your account/
    assert_not GoogleIdentity.exists?(subject: "google-sub-case")
  end

  test "a different subject cannot link onto an already-linked user" do
    state = start_google_sign_in
    complete_google_sign_in(state:, email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice")
    delete session_url

    collision_state = start_google_sign_in

    assert_no_difference -> { Session.count } do
      complete_google_sign_in(state: collision_state, email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-impostor")
    end

    assert_redirected_to new_session_url
    assert_equal "google-sub-alice", User.find_by!(email_address: "alice@smartdata.net").google_identity.subject
    assert_not GoogleIdentity.exists?(subject: "google-sub-impostor")
  end

  test "malformed id_token is rejected" do
    state = start_google_sign_in
    stub_google_jwks
    stub_sign_in_code_exchange(id_token: "not-a-jwt")

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to new_session_url
  end

  test "id_token signed by the wrong key is rejected" do
    state = start_google_sign_in
    stub_google_jwks
    stub_sign_in_code_exchange(id_token: sign_in_id_token(key: sign_in_attacker_key))

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to new_session_url
  end

  test "expired id_token is rejected" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state:, exp: 1.hour.ago.to_i)
    end

    assert_redirected_to new_session_url
  end

  test "id_token for another audience is rejected" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state:, aud: "other-client-id")
    end

    assert_redirected_to new_session_url
  end

  test "multi-audience id_token requires a matching azp" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state:, aud: [ "test-client-id", "other-client" ])
    end

    assert_redirected_to new_session_url
  end

  test "multi-audience id_token with a matching azp succeeds" do
    state = start_google_sign_in

    complete_google_sign_in(state:, aud: [ "test-client-id", "other-client" ], azp: "test-client-id")

    assert_redirected_to root_url
    assert User.exists?(email_address: "alice@smartdata.net")
  end

  test "id_token with a wrong azp is rejected" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state:, azp: "other-client-id")
    end

    assert_redirected_to new_session_url
  end

  test "id_token from an unknown issuer is rejected" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state:, iss: "https://evil.test")
    end

    assert_redirected_to new_session_url
  end

  test "id_token with a missing or wrong nonce is rejected" do
    missing_state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state: missing_state, nonce: nil)
    end
    assert_redirected_to new_session_url

    wrong_state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state: wrong_state, nonce: "attacker-nonce")
    end
    assert_redirected_to new_session_url
  end

  test "id_token with a missing or unverified email is rejected" do
    missing_state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state: missing_state, email: nil, hd: "smartdata.net")
    end
    assert_redirected_to new_session_url

    unverified_state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state: unverified_state, email_verified: false)
    end
    assert_redirected_to new_session_url
  end

  test "id_token with a missing subject is rejected" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      complete_google_sign_in(state:, sub: nil)
    end

    assert_redirected_to new_session_url
  end

  test "id_token with a non-RS256 algorithm is rejected" do
    state = start_google_sign_in
    stub_google_jwks
    forged = JWT.encode(
      { iss: "https://accounts.google.com", aud: "test-client-id", sub: "x",
        email: "alice@smartdata.net", email_verified: true, hd: "smartdata.net",
        nonce: @last_sign_in_nonce, exp: 1.hour.from_now.to_i },
      "secret", "HS256", { kid: SIGN_IN_KID, typ: "JWT" }
    )
    stub_sign_in_code_exchange(id_token: forged)

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to new_session_url
  end

  test "unknown signing key refetches once and still fails closed" do
    state = start_google_sign_in
    stub_google_jwks
    stub_sign_in_code_exchange(id_token: sign_in_id_token(kid: "unknown-key"))

    get session_google_callback_path, params: { state:, code: "auth-code" }

    assert_redirected_to new_session_url
    assert_requested :get, GOOGLE_JWKS_URL, times: 2
    assert_not User.exists?(email_address: "alice@smartdata.net")
  end

  test "key rotation succeeds through a bounded refetch" do
    other_key = OpenSSL::PKey::RSA.new(2048)
    state = start_google_sign_in
    stub_google_jwks
    # Prime the cache with a key set that lacks the rotated key.
    Google::SignIn::KeyStore.public_key_for(SIGN_IN_KID)
    stub_google_jwks(key: other_key, kid: "rotated-key")
    stub_sign_in_code_exchange(id_token: sign_in_id_token(key: other_key, kid: "rotated-key"))

    get session_google_callback_path, params: { state:, code: "auth-code" }

    assert_redirected_to root_url
    assert User.exists?(email_address: "alice@smartdata.net")
  end

  test "callback with a forged or missing state is rejected without contacting Google" do
    start_google_sign_in

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state: "bogus", code: "auth-code" }
    end
    assert_redirected_to new_session_url

    second_state = start_google_sign_in

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { code: "auth-code" }
    end
    assert_redirected_to new_session_url

    # A state signed for another flow is not valid for this one.
    other_state = start_google_sign_in
    assert_not_equal second_state, other_state

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state: second_state, code: "auth-code" }
    end
    assert_redirected_to new_session_url
    assert_not_requested :post, GOOGLE_TOKEN_URL
  end

  test "callback with an expired flow is rejected" do
    state = nil
    travel_to(11.minutes.ago) { state = start_google_sign_in }

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to new_session_url
    follow_redirect!
    assert_select ".flash", text: /expired/
    assert_not_requested :post, GOOGLE_TOKEN_URL
  end

  test "callback state cannot be replayed" do
    state = start_google_sign_in
    complete_google_sign_in(state:)
    assert_redirected_to root_url
    delete session_url

    assert_no_difference -> { Session.count } do
      get session_google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to new_session_url
  end

  test "cancelled grant redirects without signing in" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state:, error: "access_denied" }
    end

    assert_redirected_to new_session_url
    follow_redirect!
    assert_select ".flash", text: /cancelled/
    assert_not_requested :post, GOOGLE_TOKEN_URL
  end

  test "callback without a code is rejected" do
    state = start_google_sign_in

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state: }
    end

    assert_redirected_to new_session_url
    assert_not_requested :post, GOOGLE_TOKEN_URL
  end

  test "failed code exchange sends PKCE and fails without signing in" do
    state = start_google_sign_in
    stub_request(:post, GOOGLE_TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state:, code: "bad-code" }
    end

    assert_redirected_to new_session_url
    assert_requested :post, GOOGLE_TOKEN_URL, body: /code_verifier=.+&?/
    assert_requested :post, GOOGLE_TOKEN_URL, body: /grant_type=authorization_code/
  end

  test "token exchange without an id_token fails without signing in" do
    state = start_google_sign_in
    stub_sign_in_code_exchange(id_token: nil)

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to new_session_url
  end

  test "token endpoint outage fails closed with a retry message" do
    state = start_google_sign_in
    stub_request(:post, GOOGLE_TOKEN_URL).to_timeout

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to new_session_url
    follow_redirect!
    assert_select ".flash", text: /unavailable right now/
  end

  test "signing key outage fails closed with a retry message" do
    state = start_google_sign_in
    stub_request(:get, GOOGLE_JWKS_URL).to_timeout
    stub_sign_in_code_exchange

    assert_no_user_or_session_change do
      get session_google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to new_session_url
    follow_redirect!
    assert_select ".flash", text: /unavailable right now/
  end

  test "rejection logs carry no tokens or codes" do
    state = start_google_sign_in
    id_token = sign_in_id_token(hd: "gmail.com", email: "mallory@gmail.com")
    stub_google_jwks
    stub_sign_in_code_exchange(id_token:)

    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    get session_google_callback_path, params: { state:, code: "secret-auth-code" }

    assert_redirected_to new_session_url
    assert_includes log_output.string, "Google sign-in rejected"
    assert_not_includes log_output.string, id_token
    assert_not_includes log_output.string, "secret-auth-code"
  ensure
    Rails.logger = original_logger
  end

  test "authorization code is filtered from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    assert_equal "[FILTERED]", filter.filter_param("code", "secret-auth-code")
  end

  test "Google sign-in creates no Calendar/Drive connection and stores no tokens" do
    state = start_google_sign_in

    assert_no_difference -> { GoogleAccount.count } do
      complete_google_sign_in(state:)
    end

    user = User.find_by!(email_address: "alice@smartdata.net")
    assert_nil user.google_account
    assert user.google_identity
    assert_empty GoogleIdentity.column_names & %w[ access_token refresh_token ]
  end

  test "Calendar connection is never treated as login identity" do
    connect_google!(users(:david), email: "david@smartdata.net")

    state = start_google_sign_in

    complete_google_sign_in(state:, email: "david@smartdata.net", hd: "smartdata.net", sub: "google-sub-david")

    assert_redirected_to root_url
    user = GoogleIdentity.find_by!(subject: "google-sub-david").user
    assert_not_equal users(:david).id, user.id
    assert_equal users(:david).id, users(:david).reload.google_account.user_id
  end

  test "connecting Calendar creates no login identity" do
    sign_in :david
    post google_connect_path
    state = Rack::Utils.parse_query(URI(response.location).query)["state"]
    stub_google_code_exchange

    assert_no_difference -> { GoogleIdentity.count } do
      get google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to user_profile_path
  end

  test "disconnecting Calendar keeps the login identity" do
    state = start_google_sign_in
    complete_google_sign_in(state:, email: "alice@smartdata.net", hd: "smartdata.net", sub: "google-sub-alice")
    user = User.find_by!(email_address: "alice@smartdata.net")
    connect_google!(user, email: "alice@gmail.test")

    delete google_connection_path

    assert_redirected_to user_profile_path
    assert_not GoogleAccount.exists?(user:)
    assert_equal "google-sub-alice", user.reload.google_identity.subject
  end

  private
    def assert_no_user_or_session_change(&block)
      assert_no_difference -> { User.count } do
        assert_no_difference -> { Session.count }, &block
      end
    end
end
