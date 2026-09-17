require "test_helper"

class Google::ClientTest < ActiveSupport::TestCase
  include GoogleCalendarTestHelper

  setup do
    @account = connect_google!(users(:david))
    @client = Google::Client.new(@account)
  end

  test "configured? requires both client id and secret" do
    assert Google::Client.configured?

    disconnect_google_env!

    assert_not Google::Client.configured?
  end

  test "authorize_url carries the calendar scope, offline access, and state" do
    url = Google::Client.authorize_url(redirect_uri: "http://test.host/google/callback", state: "signed-state")
    query = Rack::Utils.parse_query(URI(url).query)

    assert_equal "https", URI(url).scheme
    assert_equal "test-client-id", query["client_id"]
    assert_equal "http://test.host/google/callback", query["redirect_uri"]
    assert_equal "code", query["response_type"]
    assert_equal "openid email https://www.googleapis.com/auth/calendar.events", query["scope"]
    assert_equal "offline", query["access_type"]
    assert_equal "consent", query["prompt"]
    assert_equal "signed-state", query["state"]
  end

  test "refreshes an expired access token before calling" do
    @account.update!(access_token_expires_at: 1.hour.ago)
    stub_google_token_refresh
    insert = stub_google_event_insert(body: { "id" => "abc123" })

    response = @client.insert_event({ "summary" => "Party" })

    assert_equal "abc123", response["id"]
    assert_requested :post, GOOGLE_TOKEN_URL
    assert_requested :post, GOOGLE_EVENTS_URL, headers: { "Authorization" => "Bearer refreshed-access-token" }
    assert_equal "refreshed-access-token", @account.reload.access_token
    assert @account.access_token_expires_at > 30.minutes.from_now
    assert_requested insert
  end

  test "retries once after a 401 cured by a refresh" do
    stub_google_token_refresh
    stub_request(:post, GOOGLE_EVENTS_URL)
      .to_return({ status: 401 }, { status: 200, body: {}.to_json })

    @client.insert_event({ "summary" => "Party" })

    assert_requested :post, GOOGLE_EVENTS_URL, times: 2
    assert_requested :post, GOOGLE_TOKEN_URL, times: 1
  end

  test "a 401 that survives refresh raises Unauthorized" do
    stub_google_token_refresh
    stub_request(:post, GOOGLE_EVENTS_URL).to_return(status: 401)

    assert_raises(Google::Client::Unauthorized) { @client.insert_event({}) }
  end

  test "invalid_grant marks the account disconnected and raises Unauthorized" do
    @account.update!(access_token_expires_at: 1.hour.ago)
    stub_google_token_invalid_grant

    error = assert_raises(Google::Client::Unauthorized) { @client.insert_event({}) }

    assert_equal "Google rejected the connection", @account.reload.disconnected_reason
    assert_not_predicate @account, :connected?
    assert_not_includes error.message, @account.refresh_token.to_s
  end

  test "a failed refresh without invalid_grant raises Error and keeps the connection" do
    @account.update!(access_token_expires_at: 1.hour.ago)
    stub_request(:post, GOOGLE_TOKEN_URL).to_return(status: 500, body: "boom")

    assert_raises(Google::Client::Error) { @client.insert_event({}) }
    assert_nil @account.reload.disconnected_reason
  end

  test "404 maps to NotFound" do
    stub_google_event_delete("missing-id", status: 404)

    assert_raises(Google::Client::NotFound) { @client.delete_event("missing-id") }
  end

  test "409 maps to Conflict" do
    stub_google_event_insert(status: 409, body: { "error" => { "code" => 409 } })

    assert_raises(Google::Client::Conflict) { @client.insert_event({}) }
  end

  test "other API failures map to Error" do
    stub_google_event_delete("some-id", status: 500)

    assert_raises(Google::Client::Error) { @client.delete_event("some-id") }
  end

  test "a timeout maps to Unavailable" do
    stub_request(:post, GOOGLE_EVENTS_URL).to_timeout

    error = assert_raises(Google::Client::Unavailable) { @client.insert_event({}) }

    assert Google::Client::Unavailable < Google::Client::Error
    assert_equal "Google Calendar request failed (Net::OpenTimeout)", error.message
  end

  test "a malformed response body maps to Unavailable" do
    stub_request(:post, GOOGLE_EVENTS_URL).to_return(status: 200, body: "{oops")

    error = assert_raises(Google::Client::Unavailable) { @client.insert_event({}) }

    assert_equal "Google Calendar request failed (JSON::ParserError)", error.message
  end

  test "email_from_id_token returns the verified email" do
    assert_equal "david@gmail.test", Google::Client.email_from_id_token(google_id_token)
  end

  test "email_from_id_token accepts the short issuer" do
    assert_equal "david@gmail.test",
      Google::Client.email_from_id_token(google_id_token(iss: "accounts.google.com"))
  end

  test "email_from_id_token rejects a missing or malformed token" do
    assert_raises(Google::Client::Error) { Google::Client.email_from_id_token(nil) }
    assert_raises(Google::Client::Error) { Google::Client.email_from_id_token("") }
    assert_raises(Google::Client::Error) { Google::Client.email_from_id_token("not-a-jwt") }
  end

  test "email_from_id_token rejects a wrong issuer, audience, expiry, or missing email" do
    assert_raises(Google::Client::Error) do
      Google::Client.email_from_id_token(google_id_token(iss: "https://evil.test"))
    end
    assert_raises(Google::Client::Error) do
      Google::Client.email_from_id_token(google_id_token(aud: "other-client-id"))
    end
    assert_raises(Google::Client::Error) do
      Google::Client.email_from_id_token(google_id_token(exp: 1.hour.ago.to_i))
    end
    assert_raises(Google::Client::Error) do
      Google::Client.email_from_id_token(google_id_token(email: nil))
    end
  end

  test "exchange_code returns the token response" do
    stub_google_code_exchange

    tokens = Google::Client.exchange_code(code: "auth-code", redirect_uri: "http://test.host/google/callback")

    assert_equal "new-access-token", tokens["access_token"]
    assert_equal "new-refresh-token", tokens["refresh_token"]
    assert_predicate tokens["id_token"], :present?
    assert_requested :post, GOOGLE_TOKEN_URL, body: hash_including({ "code" => "auth-code", "grant_type" => "authorization_code" })
  end

  test "a failed code exchange raises Error" do
    stub_request(:post, GOOGLE_TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    assert_raises(Google::Client::Error) { Google::Client.exchange_code(code: "bad", redirect_uri: "http://test.host/x") }
  end

  test "authorize_url with drive requests both scopes and incremental auth" do
    url = Google::Client.authorize_url(redirect_uri: "http://test.host/google/callback", state: "signed-state", drive: true)
    query = Rack::Utils.parse_query(URI(url).query)

    assert_equal "openid email https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/drive.metadata.readonly", query["scope"]
    assert_equal "true", query["include_granted_scopes"]
  end

  test "authorize_url without drive omits incremental auth" do
    url = Google::Client.authorize_url(redirect_uri: "http://test.host/google/callback", state: "signed-state")
    query = Rack::Utils.parse_query(URI(url).query)

    assert_not_includes query.keys, "include_granted_scopes"
  end

  test "drive_file fetches metadata with the Drive fields" do
    stub = stub_google_drive_file("1AbcDefGhIjKlMnOpQrSt")

    file = @client.drive_file("1AbcDefGhIjKlMnOpQrSt")

    assert_equal "Q3 Planning", file["name"]
    assert_requested stub, headers: { "Authorization" => "Bearer [REDACTED]" }
    assert_requested :get, "#{GOOGLE_DRIVE_FILES_URL}/1AbcDefGhIjKlMnOpQrSt",
      query: hash_including({
        "fields" => "id,name,mimeType,modifiedTime,owners(displayName),webViewLink,iconLink",
        "supportsAllDrives" => "true"
      })
  end

  test "drive_file refreshes an expired access token first" do
    @account.update!(access_token_expires_at: 1.hour.ago)
    stub_google_token_refresh
    file_stub = stub_google_drive_file("1AbcDefGhIjKlMnOpQrSt")

    @client.drive_file("1AbcDefGhIjKlMnOpQrSt")

    assert_requested :post, GOOGLE_TOKEN_URL
    assert_requested file_stub, headers: { "Authorization" => "Bearer [REDACTED]" }
  end

  test "drive_file maps 403 and 404 to NotFound" do
    stub_google_drive_file("forbidden-file-id", status: 403)
    stub_google_drive_file("missing-file-id1", status: 404)

    assert_raises(Google::Client::NotFound) { @client.drive_file("forbidden-file-id") }
    assert_raises(Google::Client::NotFound) { @client.drive_file("missing-file-id1") }
  end

  test "drive_file maps a timeout to Unavailable" do
    stub_request(:get, "#{GOOGLE_DRIVE_FILES_URL}/1AbcDefGhIjKlMnOpQrSt")
      .with(query: hash_including({ "supportsAllDrives" => "true" })).to_timeout

    error = assert_raises(Google::Client::Unavailable) { @client.drive_file("1AbcDefGhIjKlMnOpQrSt") }

    assert_equal "Google Drive request failed (Net::OpenTimeout)", error.message
  end

  test "list_drive_files requests the recent list with the Drive list parameters" do
    stub = stub_google_drive_list

    result = @client.list_drive_files(query: "")

    assert_equal [ "Q3 Planning", "Budget 2026" ], result["files"].map { |file| file["name"] }
    assert_requested stub, headers: { "Authorization" => "Bearer [REDACTED]" }
    assert_requested :get, GOOGLE_DRIVE_FILES_URL,
      query: {
        "q" => "trashed=false",
        "pageSize" => "10",
        "fields" => "files(id,name,mimeType,modifiedTime,owners(displayName),webViewLink)",
        "orderBy" => "modifiedTime desc",
        "spaces" => "drive"
      }
  end

  test "list_drive_files searches by name and escapes quotes and backslashes" do
    stub_google_drive_list

    @client.list_drive_files(query: "bob's\\draft")

    assert_requested :get, GOOGLE_DRIVE_FILES_URL,
      query: hash_including({ "q" => "name contains 'bob\\'s\\\\draft' and trashed=false" })
  end

  test "list_drive_files treats a blank query as a recent list" do
    stub_google_drive_list

    @client.list_drive_files(query: "   ")

    assert_requested :get, GOOGLE_DRIVE_FILES_URL,
      query: hash_including({ "q" => "trashed=false" })
  end

  test "list_drive_files refreshes an expired access token first" do
    @account.update!(access_token_expires_at: 1.hour.ago)
    stub_google_token_refresh
    list_stub = stub_google_drive_list

    @client.list_drive_files(query: "")

    assert_requested :post, GOOGLE_TOKEN_URL
    assert_requested list_stub, headers: { "Authorization" => "Bearer [REDACTED]" }
  end
end
