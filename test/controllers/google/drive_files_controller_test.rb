require "test_helper"

class Google::DriveFilesControllerTest < ActionDispatch::IntegrationTest
  include GoogleCalendarTestHelper

  setup do
    sign_in :david
    @david = users(:david)
  end

  test "show renders the file JSON for a connected account with the Drive scope" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    stub_google_drive_file("1AbcDefGhIjKlMnOpQrSt")

    get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal(
      {
        "id" => "1AbcDefGhIjKlMnOpQrSt",
        "name" => "Q3 Planning",
        "kind" => "document",
        "modified_at" => "2026-09-16T10:30:00.000Z",
        "owner" => "Riel",
        "url" => "https://docs.google.com/document/d/1AbcDefGhIjKlMnOpQrSt/edit"
      },
      response.parsed_body
    )
  end

  test "show maps MIME types to kinds" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    cases = {
      "application/vnd.google-apps.spreadsheet" => "spreadsheet",
      "application/vnd.google-apps.presentation" => "presentation",
      "application/vnd.google-apps.form" => "form",
      "application/vnd.google-apps.folder" => "folder",
      "application/pdf" => "pdf",
      "image/png" => "file",
      "application/vnd.google-apps.unknown" => "file"
    }

    cases.each_with_index do |(mime_type, kind), index|
      file_id = "kind-mapping-#{index}1"
      stub_google_drive_file(file_id, body: drive_file_payload(mime_type: mime_type).merge("id" => file_id))

      get google_drive_file_path(file_id), headers: { "Accept" => "application/json" }

      assert_response :success, "expected 200 for #{mime_type}"
      assert_equal kind, response.parsed_body["kind"], "wrong kind for #{mime_type}"
    end
  end

  test "show is 404 with an empty body without an account" do
    get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body
    assert_not_requested :get, %r{\A#{Regexp.escape(GOOGLE_DRIVE_FILES_URL)}/}
  end

  test "show is 404 with an empty body for a disconnected account" do
    connect_google!(@david, scopes: DRIVE_SCOPES, disconnected_reason: "Google rejected the connection")

    get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body
    assert_not_requested :get, %r{\A#{Regexp.escape(GOOGLE_DRIVE_FILES_URL)}/}
  end

  test "show is 404 with an empty body without the Drive scope" do
    connect_google!(@david)

    get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body
    assert_not_requested :get, %r{\A#{Regexp.escape(GOOGLE_DRIVE_FILES_URL)}/}
  end

  test "show is 404 with an empty body when Google answers 403 or 404" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    stub_google_drive_file("forbidden-file-id", status: 403)
    stub_google_drive_file("missing-file-id1", status: 404)

    get google_drive_file_path("forbidden-file-id"), headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body

    get google_drive_file_path("missing-file-id1"), headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body
  end

  test "show is 404 with an empty body for a malformed id" do
    connect_google!(@david, scopes: DRIVE_SCOPES)

    get google_drive_file_path("short"), headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body

    get google_drive_file_path("not a file id!!"), headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body
    assert_not_requested :get, %r{\A#{Regexp.escape(GOOGLE_DRIVE_FILES_URL)}/}
  end

  test "show is 503 on a Google transport failure" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    stub_request(:get, "#{GOOGLE_DRIVE_FILES_URL}/1AbcDefGhIjKlMnOpQrSt")
      .with(query: hash_including({ "supportsAllDrives" => "true" })).to_timeout

    get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }

    assert_response :service_unavailable
  end

  test "show requires sign-in" do
    delete session_path

    get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }

    assert_redirected_to new_session_url
  end

  test "show caches the file for five minutes per viewer" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    file_stub = stub_google_drive_file("1AbcDefGhIjKlMnOpQrSt")

    with_memory_cache do
      get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }
      assert_response :success

      get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }
      assert_response :success

      assert_requested file_stub, times: 1
    end
  end

  test "show never reuses another viewer\'s cache entry" do
    jason = users(:jason)
    connect_google!(@david, scopes: DRIVE_SCOPES)
    connect_google!(jason, scopes: DRIVE_SCOPES)
    file_stub = stub_google_drive_file("1AbcDefGhIjKlMnOpQrSt")

    with_memory_cache do |store|
      get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }
      assert_response :success

      sign_in jason
      get google_drive_file_path("1AbcDefGhIjKlMnOpQrSt"), headers: { "Accept" => "application/json" }
      assert_response :success

      # A shared entry would have answered the second viewer without a new
      # Google request; each viewer fetched (and cached) separately instead.
      assert_requested file_stub, times: 2
      assert store.exist?("google_drive_file/#{@david.id}/1AbcDefGhIjKlMnOpQrSt")
      assert store.exist?("google_drive_file/#{jason.id}/1AbcDefGhIjKlMnOpQrSt")
    end
  end

  test "index lists recent files when q is blank" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    list_stub = stub_google_drive_list

    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal(
      {
        "files" => [
          {
            "id" => "1AbcDefGhIjKlMnOpQrSt",
            "name" => "Q3 Planning",
            "kind" => "document",
            "modified_at" => "2026-09-16T10:30:00.000Z",
            "owner" => "Riel",
            "url" => "https://docs.google.com/document/d/1AbcDefGhIjKlMnOpQrSt/edit"
          },
          {
            "id" => "2BcdEfgHiJkLmNoPqRsTu",
            "name" => "Budget 2026",
            "kind" => "spreadsheet",
            "modified_at" => "2026-09-15T09:00:00.000Z",
            "owner" => "Jon",
            "url" => "https://docs.google.com/spreadsheets/d/2BcdEfgHiJkLmNoPqRsTu/edit"
          }
        ]
      },
      response.parsed_body
    )
    assert_requested list_stub, query: hash_including({
      "q" => "trashed=false",
      "pageSize" => "10",
      "fields" => "files(id,name,mimeType,modifiedTime,owners(displayName),webViewLink)",
      "orderBy" => "modifiedTime desc",
      "spaces" => "drive"
    })
  end

  test "index treats whitespace-only q as a recent list" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    list_stub = stub_google_drive_list

    get google_drive_files_path(q: "   "), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_requested list_stub, query: hash_including({ "q" => "trashed=false" })
  end

  test "index searches by name with quote and backslash escaping" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    list_stub = stub_google_drive_list

    get google_drive_files_path(q: "bob's\\draft"), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_requested list_stub, query: hash_including({
      "q" => "name contains 'bob\\'s\\\\draft' and trashed=false"
    })
  end

  test "index trims q and caps it at 100 characters" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    list_stub = stub_google_drive_list

    get google_drive_files_path(q: "  plan  "), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_requested list_stub, query: hash_including({ "q" => "name contains 'plan' and trashed=false" })

    WebMock.reset!
    list_stub = stub_google_drive_list

    get google_drive_files_path(q: "a" * 150), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_requested list_stub, query: hash_including({ "q" => "name contains '#{"a" * 100}' and trashed=false" })
  end

  test "index maps unknown MIME types to file" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    stub_google_drive_list(files: [
      drive_list_payload["files"].first.merge("mimeType" => "image/png")
    ])

    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal "file", response.parsed_body["files"].first["kind"]
  end

  test "index is 404 with an empty body without Drive consent" do
    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body

    connect_google!(@david)

    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body
    assert_not_requested :get, GOOGLE_DRIVE_FILES_URL
  end

  test "index is 404 with an empty body for a disconnected account" do
    connect_google!(@david, scopes: DRIVE_SCOPES, disconnected_reason: "Google rejected the connection")

    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body
    assert_not_requested :get, GOOGLE_DRIVE_FILES_URL
  end

  test "index is 404 when signed out" do
    delete session_path

    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body
  end

  test "index is 502 when Google fails" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    stub_google_drive_list(status: 500)

    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :bad_gateway
    assert_equal({ "error" => "drive_unavailable" }, response.parsed_body)
  end

  test "index is 404 when Drive answers forbidden" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    stub_google_drive_list(status: 403)

    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :not_found
  end

  test "index is 404 when the refresh fails with invalid_grant" do
    account = connect_google!(@david, scopes: DRIVE_SCOPES)
    account.update!(access_token_expires_at: 1.hour.ago)
    stub_google_token_invalid_grant

    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_equal "Google rejected the connection", account.reload.disconnected_reason
  end

  test "index refreshes an expired access token before listing" do
    account = connect_google!(@david, scopes: DRIVE_SCOPES)
    account.update!(access_token_expires_at: 1.hour.ago)
    stub_google_token_refresh
    list_stub = stub_google_drive_list

    get google_drive_files_path, headers: { "Accept" => "application/json" }

    assert_response :success
    assert_requested :post, GOOGLE_TOKEN_URL, times: 1
    assert_requested list_stub, headers: { "Authorization" => "Bearer [REDACTED]" }
    assert_equal "refreshed-access-token", account.reload.access_token
  end

  test "index throttles each user to 30 lists per minute" do
    jason = users(:jason)
    connect_google!(@david, scopes: DRIVE_SCOPES)
    connect_google!(jason, scopes: DRIVE_SCOPES)
    list_stub = stub_google_drive_list

    with_memory_cache do
      30.times do
        get google_drive_files_path, headers: { "Accept" => "application/json" }
        assert_response :success
      end

      get google_drive_files_path, headers: { "Accept" => "application/json" }

      assert_response :too_many_requests
      assert_equal({ "error" => "rate_limited" }, response.parsed_body)
      assert_requested list_stub, times: 30

      sign_in jason
      get google_drive_files_path, headers: { "Accept" => "application/json" }

      assert_response :success
    end
  end

  test "index never caches results" do
    connect_google!(@david, scopes: DRIVE_SCOPES)
    list_stub = stub_google_drive_list

    with_memory_cache do
      2.times do
        get google_drive_files_path, headers: { "Accept" => "application/json" }
        assert_response :success
      end

      assert_requested list_stub, times: 2
    end
  end

  private
    # The test environment uses :null_store; swap in a memory store so cache
    # behavior is exercisable.
    def with_memory_cache
      store = ActiveSupport::Cache::MemoryStore.new
      previous = Rails.cache
      Rails.cache = store
      yield store
    ensure
      Rails.cache = previous
    end
end
