require "test_helper"

class Rooms::DriveRecipientsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @picker_env_before_test = [ ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_PICKER_API_KEY"], ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] ]
    ENV["GOOGLE_CLIENT_ID"] = "test-client-id"
    ENV["GOOGLE_PICKER_API_KEY"] = "test-picker-key"
    ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = "123456789012"

    sign_in :jz
    @room = rooms(:designers)
  end

  teardown do
    ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_PICKER_API_KEY"], ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = @picker_env_before_test
  end

  test "index previews eligible members without the requester, ordered by name" do
    get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal(
      [
        { "id" => users(:david).id, "name" => "David", "email" => "david@37signals.com" },
        { "id" => users(:jason).id, "name" => "Jason", "email" => "jason@37signals.com" },
        { "id" => users(:kevin).id, "name" => "Kevin", "email" => "kevin@37signals.com" }
      ],
      response.parsed_body["recipients"]
    )
  end

  test "index needs no Calendar or Drive consent" do
    assert_nil users(:jz).google_account

    get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }

    assert_response :success
  end

  test "index excludes bots" do
    room = rooms(:watercooler)
    sign_in users(:david)

    get room_drive_recipients_path(room), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal [ users(:jason).id ], response.parsed_body["recipients"].map { |recipient| recipient["id"] }
  end

  test "index excludes agent-backed users, deactivated, banned, and unusable emails" do
    kevin = users(:kevin)
    Agent.create!(user: kevin, owner: users(:david))
    users(:jason).update!(status: :deactivated)

    outsider = User.create!(name: "Zed Outsider", email_address: "zed@external.test", password: "secret123456")
    @room.memberships.grant_to(outsider)
    blank_email = User.create!(name: "Blank Email", email_address: "blank@external.test", password: "secret123456")
    blank_email.update_column(:email_address, "")
    @room.memberships.grant_to(blank_email)
    invalid_email = User.create!(name: "Invalid Email", email_address: "invalid@external.test", password: "secret123456")
    invalid_email.update_column(:email_address, "not-an-email")
    @room.memberships.grant_to(invalid_email)
    banned = User.create!(name: "Banned Member", email_address: "banned@external.test", password: "secret123456")
    @room.memberships.grant_to(banned)
    banned.update!(status: :banned)

    get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal(
      [
        { "id" => users(:david).id, "name" => "David", "email" => "david@37signals.com" },
        { "id" => outsider.id, "name" => "Zed Outsider", "email" => "zed@external.test" }
      ],
      response.parsed_body["recipients"]
    )
  end

  test "index spans both company domains and password-login external members with no domain filter" do
    smartdata = User.create!(name: "Amy Smart", email_address: "amy@smartdata.net", password: "secret123456")
    cnbs = User.create!(name: "Bob Cnbs", email_address: "bob@cnbssoftware.com", password: "secret123456")
    external = User.create!(name: "Cal External", email_address: "cal@contractor.test", password: "secret123456")
    @room.memberships.grant_to([ smartdata, cnbs, external ])

    get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }

    assert_response :success
    emails = response.parsed_body["recipients"].map { |recipient| recipient["email"] }
    assert_includes emails, "amy@smartdata.net"
    assert_includes emails, "bob@cnbssoftware.com"
    assert_includes emails, "cal@contractor.test"
  end

  test "index is 404 when sharing is not configured" do
    ENV.delete("GOOGLE_PICKER_API_KEY")

    get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_empty response.body
  end

  test "index is 404 when the project number is missing" do
    ENV.delete("GOOGLE_CLOUD_PROJECT_NUMBER")

    get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }

    assert_response :not_found
  end

  test "index is 401 when signed out and leaks no emails" do
    delete session_path

    get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }

    assert_response :unauthorized
    assert_not_includes response.body, "37signals.com"
  end

  test "index is 404 for a nonmember and leaks no emails" do
    sign_in users(:jz)

    get room_drive_recipients_path(rooms(:pets)), headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_not_includes response.body, "37signals.com"
  end

  test "index is 403 for bot-key and agent-token requests" do
    delete session_path

    get room_drive_recipients_path(@room, bot_key: users(:bender).bot_key), headers: { "Accept" => "application/json" }
    assert_response :forbidden

    get room_drive_recipients_path(@room), headers: {
      "Accept" => "application/json", "Authorization" => "Bearer bender-test-secret-1234"
    }
    assert_response :forbidden
  end

  test "index is 403 for an agent-backed user over a session" do
    Agent.create!(user: users(:jz), owner: users(:david))

    get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }

    assert_response :forbidden
  end

  test "index throttles each user to 60 previews per minute" do
    travel_to Time.current.beginning_of_minute + 5.seconds

    with_memory_cache do
      60.times do
        get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }
        assert_response :success
      end

      get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }

      assert_response :too_many_requests
      assert_equal({ "error" => "rate_limited" }, response.parsed_body)
    end
  end

  test "validate returns the canonical recipients for a current selection" do
    post validate_room_drive_recipients_path(@room),
      params: { user_ids: [ users(:kevin).id, users(:david).id ] },
      headers: { "Accept" => "application/json" }, as: :json

    assert_response :success
    assert_equal(
      [
        { "id" => users(:kevin).id, "name" => "Kevin", "email" => "kevin@37signals.com" },
        { "id" => users(:david).id, "name" => "David", "email" => "david@37signals.com" }
      ],
      response.parsed_body["recipients"]
    )
  end

  test "validate collapses duplicate ids" do
    post validate_room_drive_recipients_path(@room),
      params: { user_ids: [ users(:david).id, users(:david).id ] },
      headers: { "Accept" => "application/json" }, as: :json

    assert_response :success
    assert_equal [ users(:david).id ], response.parsed_body["recipients"].map { |recipient| recipient["id"] }
  end

  test "validate rejects a removed member selected from a stale preview" do
    get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }
    assert_includes response.parsed_body["recipients"].map { |recipient| recipient["id"] }, users(:kevin).id

    @room.memberships.revoke_from(users(:kevin))

    post validate_room_drive_recipients_path(@room),
      params: { user_ids: [ users(:kevin).id, users(:david).id ] },
      headers: { "Accept" => "application/json" }, as: :json

    assert_response :unprocessable_content
    assert_equal(
      { "error" => "invalid_recipients", "invalid_ids" => [ users(:kevin).id ] },
      response.parsed_body
    )
  end

  test "validate rejects self, bots, nonmembers, and unknown ids" do
    outsider = User.create!(name: "Outsider", email_address: "outsider@external.test", password: "secret123456")

    post validate_room_drive_recipients_path(@room),
      params: { user_ids: [ users(:jz).id, users(:bender).id, outsider.id, User.maximum(:id).to_i + 100 ] },
      headers: { "Accept" => "application/json" }, as: :json

    assert_response :unprocessable_content
    assert_equal(
      {
        "error" => "invalid_recipients",
        "invalid_ids" => [ users(:jz).id, users(:bender).id, outsider.id, User.maximum(:id).to_i + 100 ]
      },
      response.parsed_body
    )
  end

  test "validate rejects an agent-backed selection and a deactivated member" do
    Agent.create!(user: users(:kevin), owner: users(:david))
    users(:david).update!(status: :deactivated)

    post validate_room_drive_recipients_path(@room),
      params: { user_ids: [ users(:kevin).id, users(:david).id ] },
      headers: { "Accept" => "application/json" }, as: :json

    assert_response :unprocessable_content
    assert_equal(
      { "error" => "invalid_recipients", "invalid_ids" => [ users(:kevin).id, users(:david).id ] },
      response.parsed_body
    )
  end

  test "validate rejects a scalar, a missing key, and arbitrary emails" do
    post validate_room_drive_recipients_path(@room),
      params: { user_ids: users(:david).id },
      headers: { "Accept" => "application/json" }, as: :json
    assert_response :unprocessable_content
    assert_equal({ "error" => "invalid_recipients" }, response.parsed_body)

    post validate_room_drive_recipients_path(@room),
      headers: { "Accept" => "application/json" }, as: :json
    assert_response :unprocessable_content
    assert_equal({ "error" => "invalid_recipients" }, response.parsed_body)

    post validate_room_drive_recipients_path(@room),
      params: { user_ids: [ "stranger@external.test" ] },
      headers: { "Accept" => "application/json" }, as: :json
    assert_response :unprocessable_content
    assert_equal({ "error" => "invalid_recipients" }, response.parsed_body)
  end

  test "validate rejects a selection larger than 100" do
    post validate_room_drive_recipients_path(@room),
      params: { user_ids: (1..101).to_a },
      headers: { "Accept" => "application/json" }, as: :json

    assert_response :unprocessable_content
    assert_equal({ "error" => "too_many_recipients", "limit" => 100 }, response.parsed_body)
  end

  test "validate is 404 when sharing is not configured" do
    ENV.delete("GOOGLE_PICKER_API_KEY")

    post validate_room_drive_recipients_path(@room),
      params: { user_ids: [ users(:david).id ] },
      headers: { "Accept" => "application/json" }, as: :json

    assert_response :not_found
  end

  test "validate is 401 when signed out, 404 for a nonmember, 403 for bots" do
    delete session_path
    post validate_room_drive_recipients_path(@room),
      params: { user_ids: [ users(:david).id ] },
      headers: { "Accept" => "application/json" }, as: :json
    assert_response :unauthorized

    sign_in users(:jz)
    post validate_room_drive_recipients_path(rooms(:pets)),
      params: { user_ids: [ users(:david).id ] },
      headers: { "Accept" => "application/json" }, as: :json
    assert_response :not_found

    delete session_path
    post validate_room_drive_recipients_path(@room, bot_key: users(:bender).bot_key),
      params: { user_ids: [ users(:david).id ] },
      headers: { "Accept" => "application/json" }, as: :json
    assert_response :forbidden
  end

  test "validate requires a CSRF token" do
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_raises(ActionController::InvalidAuthenticityToken) do
      post validate_room_drive_recipients_path(@room),
        params: { user_ids: [ users(:david).id ] },
        headers: { "Accept" => "application/json" }, as: :json
    end
  ensure
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  test "validate shares the recipient throttle bucket" do
    travel_to Time.current.beginning_of_minute + 5.seconds

    with_memory_cache do
      59.times do
        get room_drive_recipients_path(@room), headers: { "Accept" => "application/json" }
        assert_response :success
      end

      post validate_room_drive_recipients_path(@room),
        params: { user_ids: [ users(:david).id ] },
        headers: { "Accept" => "application/json" }, as: :json
      assert_response :success

      post validate_room_drive_recipients_path(@room),
        params: { user_ids: [ users(:david).id ] },
        headers: { "Accept" => "application/json" }, as: :json
      assert_response :too_many_requests
      assert_equal({ "error" => "rate_limited" }, response.parsed_body)
    end
  end

  private
    # The test environment uses :null_store; swap in a memory store so
    # throttle behavior is exercisable.
    def with_memory_cache
      store = ActiveSupport::Cache::MemoryStore.new
      previous = Rails.cache
      Rails.cache = store
      yield store
    ensure
      Rails.cache = previous
    end
end
