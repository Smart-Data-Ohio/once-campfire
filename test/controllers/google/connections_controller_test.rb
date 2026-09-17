require "test_helper"

class Google::ConnectionsControllerTest < ActionDispatch::IntegrationTest
  include GoogleCalendarTestHelper

  setup do
    sign_in :david
    @david = users(:david)
  end

  test "connect redirects to Google with the right scope and a state" do
    post google_connect_path

    assert_response :redirect
    uri = URI(response.location)
    query = Rack::Utils.parse_query(uri.query)
    assert_equal "accounts.google.com", uri.host
    assert_equal "test-client-id", query["client_id"]
    assert_equal google_callback_url, query["redirect_uri"]
    assert_equal "code", query["response_type"]
    assert_equal "openid email https://www.googleapis.com/auth/calendar.events", query["scope"]
    assert_equal "offline", query["access_type"]
    assert_equal "consent", query["prompt"]
    assert_predicate query["state"], :present?
  end

  test "connect requires sign-in" do
    delete session_path

    post google_connect_path

    assert_redirected_to new_session_url
  end

  test "connect with features[]=drive requests both scopes with incremental auth" do
    post google_connect_path, params: { features: [ "drive" ] }

    assert_response :redirect
    query = Rack::Utils.parse_query(URI(response.location).query)
    assert_equal "openid email https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/drive.metadata.readonly", query["scope"]
    assert_equal "true", query["include_granted_scopes"]
  end

  test "connect without features requests only the Calendar scope" do
    post google_connect_path

    assert_response :redirect
    query = Rack::Utils.parse_query(URI(response.location).query)
    assert_equal "openid email https://www.googleapis.com/auth/calendar.events", query["scope"]
    assert_not_includes query.keys, "include_granted_scopes"
  end

  test "callback with a bad state is 422" do
    get google_callback_path, params: { state: "bogus", code: "auth-code" }

    assert_response :unprocessable_content
    assert_not GoogleAccount.exists?(user: @david)
  end

  test "callback success stores the account and enqueues syncs for upcoming going/maybe attendances" do
    state = connect_state_from_redirect
    stub_google_code_exchange

    # launch_party and watercooler_sync are upcoming and going; retro is cancelled.
    assert_enqueued_jobs 2, only: Calendar::SyncEntryJob do
      get google_callback_path, params: { state:, code: "auth-code" }
    end

    assert_redirected_to user_profile_path
    account = @david.reload.google_account
    assert_equal "david@gmail.test", account.email
    assert_equal "new-refresh-token", account.refresh_token
    assert_equal "new-access-token", account.access_token
    assert_not_nil account.access_token_expires_at
    assert_nil account.disconnected_reason

    synced_event_ids = enqueued_jobs
      .select { |enqueued| enqueued[:job] == Calendar::SyncEntryJob }
      .map { |enqueued| enqueued[:args] }
    assert_equal [ [ events(:launch_party).id, @david.id ], [ events(:watercooler_sync).id, @david.id ] ].sort,
      synced_event_ids.sort
  end

  test "callback stores the granted scope string" do
    state = connect_state_from_redirect
    stub_google_code_exchange(scope: DRIVE_SCOPES)

    get google_callback_path, params: { state:, code: "auth-code" }

    assert_redirected_to user_profile_path
    assert_equal DRIVE_SCOPES, @david.reload.google_account.scopes
    assert_predicate @david.google_account, :drive?
  end

  test "callback without a scope string leaves scopes unset" do
    state = connect_state_from_redirect
    stub_google_code_exchange

    get google_callback_path, params: { state:, code: "auth-code" }

    assert_redirected_to user_profile_path
    assert_nil @david.reload.google_account.scopes
    assert_not_predicate @david.google_account, :drive?
  end

  test "callback without a scope string keeps previously stored scopes" do
    connect_google!(@david, scopes: DRIVE_SCOPES, disconnected_reason: "Google rejected the connection")
    state = connect_state_from_redirect
    stub_google_code_exchange

    get google_callback_path, params: { state:, code: "auth-code" }

    assert_redirected_to user_profile_path
    assert_equal DRIVE_SCOPES, @david.reload.google_account.scopes
  end

  test "callback clears a previous disconnected reason on reconnect" do
    connect_google!(@david, disconnected_reason: "Google rejected the connection")
    state = connect_state_from_redirect
    stub_google_code_exchange

    get google_callback_path, params: { state:, code: "auth-code" }

    assert_redirected_to user_profile_path
    assert_nil @david.reload.google_account.disconnected_reason
  end

  test "callback with a denied grant redirects without storing" do
    state = connect_state_from_redirect

    get google_callback_path, params: { state:, error: "access_denied" }

    assert_redirected_to user_profile_path
    assert_not GoogleAccount.exists?(user: @david)
  end

  test "callback with a failed exchange redirects without storing" do
    state = connect_state_from_redirect
    stub_request(:post, GOOGLE_TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    get google_callback_path, params: { state:, code: "bad-code" }

    assert_redirected_to user_profile_path
    assert_not GoogleAccount.exists?(user: @david)
  end

  test "callback without an id_token redirects without storing" do
    state = connect_state_from_redirect
    stub_google_code_exchange(id_token: nil)

    get google_callback_path, params: { state:, code: "auth-code" }

    assert_redirected_to user_profile_path
    assert_not GoogleAccount.exists?(user: @david)
  end

  test "callback with an id_token for another client redirects without storing" do
    state = connect_state_from_redirect
    stub_google_code_exchange(id_token: google_id_token(aud: "other-client-id"))

    get google_callback_path, params: { state:, code: "auth-code" }

    assert_redirected_to user_profile_path
    assert_not GoogleAccount.exists?(user: @david)
  end

  test "disconnect deletes the Google entries and destroys the account" do
    connect_google!(@david)
    first = EventCalendarEntry.create!(event: events(:launch_party), user: @david, google_event_id: SecureRandom.hex(16))
    second = EventCalendarEntry.create!(event: events(:watercooler_sync), user: @david, google_event_id: SecureRandom.hex(16))
    first_delete = stub_google_event_delete(first.google_event_id)
    second_delete = stub_google_event_delete(second.google_event_id)

    delete google_connection_path

    assert_redirected_to user_profile_path
    assert_requested first_delete
    assert_requested second_delete
    assert_not EventCalendarEntry.exists?(user: @david)
    assert_not GoogleAccount.exists?(user: @david)
  end

  test "disconnect is best effort when Google fails" do
    connect_google!(@david)
    entry = EventCalendarEntry.create!(event: events(:launch_party), user: @david, google_event_id: SecureRandom.hex(16))
    stub_google_event_delete(entry.google_event_id, status: 500)

    delete google_connection_path

    assert_redirected_to user_profile_path
    assert_not EventCalendarEntry.exists?(user: @david)
    assert_not GoogleAccount.exists?(user: @david)
  end

  test "disconnect without a connection still redirects" do
    delete google_connection_path

    assert_redirected_to user_profile_path
  end

  test "disconnect only touches the current user's entries" do
    connect_google!(@david)
    connect_google!(users(:jason))
    mine = EventCalendarEntry.create!(event: events(:launch_party), user: @david, google_event_id: SecureRandom.hex(16))
    theirs = EventCalendarEntry.create!(event: events(:launch_party), user: users(:jason), google_event_id: SecureRandom.hex(16))
    stub_google_event_delete(mine.google_event_id)

    delete google_connection_path

    assert_not_requested :delete, "#{GOOGLE_EVENTS_URL}/#{theirs.google_event_id}"
    assert EventCalendarEntry.exists?(theirs.id)
    assert GoogleAccount.exists?(user: users(:jason))
  end

  test "routes 404 when GOOGLE_CLIENT_ID is unset" do
    disconnect_google_env!

    post google_connect_path
    assert_response :not_found

    get google_callback_path, params: { state: "x", code: "y" }
    assert_response :not_found

    delete google_connection_path
    assert_response :not_found
  end

  private
    def connect_state_from_redirect
      post google_connect_path
      assert_response :redirect
      Rack::Utils.parse_query(URI(response.location).query)["state"]
    end
end
