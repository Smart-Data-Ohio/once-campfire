module GoogleCalendarTestHelper
  extend ActiveSupport::Concern

  GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
  GOOGLE_EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
  GOOGLE_DRIVE_FILES_URL = "https://www.googleapis.com/drive/v3/files"
  DRIVE_SCOPES = "openid email https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/drive.metadata.readonly"

  included do
    setup :configure_google_for_test
    teardown :restore_google_config_after_test
  end

  def connect_google!(user, **attributes)
    GoogleAccount.create!(
      user:,
      email: "#{user.name.parameterize}@gmail.test",
      refresh_token: "refresh-token-#{user.id}",
      access_token: "access-token-#{user.id}",
      access_token_expires_at: 1.hour.from_now,
      **attributes
    )
  end

  def disconnect_google_env!
    ENV.delete("GOOGLE_CLIENT_ID")
    ENV.delete("GOOGLE_CLIENT_SECRET")
  end

  private
    def configure_google_for_test
      @google_env_before_test = [ ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] ]
      ENV["GOOGLE_CLIENT_ID"] = "test-client-id"
      ENV["GOOGLE_CLIENT_SECRET"] = "test-client-secret"
    end

    def restore_google_config_after_test
      ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] = @google_env_before_test
    end

    def stub_google_token_refresh(access_token: "refreshed-access-token", expires_in: 3600)
      stub_request(:post, GOOGLE_TOKEN_URL).to_return(
        status: 200,
        body: { access_token:, expires_in:, token_type: "Bearer" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    def stub_google_token_invalid_grant
      stub_request(:post, GOOGLE_TOKEN_URL).to_return(
        status: 400,
        body: { error: "invalid_grant", error_description: "Token has been expired or revoked." }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    def stub_google_code_exchange(access_token: "new-access-token", refresh_token: "new-refresh-token", id_token: google_id_token, scope: nil)
      body = { access_token:, refresh_token:, expires_in: 3600, token_type: "Bearer" }
      body[:id_token] = id_token if id_token
      body[:scope] = scope if scope
      stub_request(:post, GOOGLE_TOKEN_URL).to_return(
        status: 200,
        body: body.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    # Real-shaped OIDC id_token (header.payload.signature, base64url JSON).
    # The app verifies iss/aud/exp but never checks the test signature.
    def google_id_token(email: "david@gmail.test", aud: "test-client-id", iss: "https://accounts.google.com", exp: 1.hour.from_now.to_i)
      segments = [
        { alg: "RS256", kid: "test-key", typ: "JWT" },
        { iss:, aud:, exp:, email:, sub: "google-sub-123" }
      ].map { |part| Base64.urlsafe_encode64(part.to_json, padding: false) }
      segments.join(".") + "." + Base64.urlsafe_encode64("test-signature", padding: false)
    end

    def stub_google_event_insert(status: 200, body: {})
      stub_request(:post, GOOGLE_EVENTS_URL).to_return(
        status:, body: body.to_json, headers: { "Content-Type" => "application/json" }
      )
    end

    def stub_google_event_update(google_event_id, status: 200, body: {})
      stub_request(:put, "#{GOOGLE_EVENTS_URL}/#{google_event_id}").to_return(
        status:, body: body.to_json, headers: { "Content-Type" => "application/json" }
      )
    end

    def stub_google_event_delete(google_event_id, status: 204)
      stub_request(:delete, "#{GOOGLE_EVENTS_URL}/#{google_event_id}").to_return(status:)
    end

    def stub_google_drive_file(file_id, status: 200, body: drive_file_payload)
      stub_request(:get, "#{GOOGLE_DRIVE_FILES_URL}/#{file_id}")
        .with(query: hash_including({ "supportsAllDrives" => "true" }))
        .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end

    def stub_google_drive_list(status: 200, body: drive_list_payload, files: nil)
      body = drive_list_payload(files:) if files
      stub_request(:get, GOOGLE_DRIVE_FILES_URL)
        .with(query: hash_including({ "pageSize" => "10" }))
        .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end

    def drive_list_payload(files: nil)
      files ||= [
        {
          "id" => "1AbcDefGhIjKlMnOpQrSt",
          "name" => "Q3 Planning",
          "mimeType" => "application/vnd.google-apps.document",
          "modifiedTime" => "2026-09-16T10:30:00.000Z",
          "owners" => [ { "displayName" => "Riel" } ],
          "webViewLink" => "https://docs.google.com/document/d/1AbcDefGhIjKlMnOpQrSt/edit"
        },
        {
          "id" => "2BcdEfgHiJkLmNoPqRsTu",
          "name" => "Budget 2026",
          "mimeType" => "application/vnd.google-apps.spreadsheet",
          "modifiedTime" => "2026-09-15T09:00:00.000Z",
          "owners" => [ { "displayName" => "Jon" } ],
          "webViewLink" => "https://docs.google.com/spreadsheets/d/2BcdEfgHiJkLmNoPqRsTu/edit"
        }
      ]
      { "files" => files }
    end

    def drive_file_payload(name: "Q3 Planning", mime_type: "application/vnd.google-apps.document")
      {
        "id" => "1AbcDefGhIjKlMnOpQrSt",
        "name" => name,
        "mimeType" => mime_type,
        "modifiedTime" => "2026-09-16T10:30:00.000Z",
        "owners" => [ { "displayName" => "Riel" } ],
        "webViewLink" => "https://docs.google.com/document/d/1AbcDefGhIjKlMnOpQrSt/edit",
        "iconLink" => "https://drive-thirdparty.googleusercontent.com/16/type/document"
      }
    end
end
