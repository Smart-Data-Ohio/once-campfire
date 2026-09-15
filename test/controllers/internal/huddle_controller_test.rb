require "test_helper"

class Internal::HuddleControllerTest < ActionDispatch::IntegrationTest
  setup do
    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"

    membership = memberships(:david_watercooler)
    @huddle = Huddle.new(room: membership.room, user: membership.user, session: sessions(:david_safari), membership: membership)
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each { |name, value| ENV[name] = value }
  end

  test "authorizes an exact active grant from an original token" do
    post_authorize(@huddle.token)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal expected_payload, response.parsed_body
  end

  test "authorizes a server-refreshed token that omits false permissions" do
    claims = decoded_claims(@huddle.token)
    claims.fetch("video").delete_if { |_permission, value| value == false }

    post_authorize(signed_token(claims))

    assert_response :success
    assert_equal expected_payload, response.parsed_body
  end

  test "rejects invalid signatures, missing time claims, and expired tokens" do
    claims = decoded_claims(@huddle.token)
    post_authorize(JWT.encode(claims, "wrong-secret", "HS256"))
    assert_response :unauthorized

    claims = decoded_claims(@huddle.token).except("nbf")
    post_authorize(signed_token(claims))
    assert_response :unauthorized

    claims = decoded_claims(@huddle.token).merge("exp" => 1.minute.ago.to_i)
    post_authorize(signed_token(claims))
    assert_response :unauthorized
  end

  test "rejects admin, data, camera, metadata, and unknown privileges" do
    privileged_grants = [
      { "roomAdmin" => true },
      { "canPublishData" => true },
      { "canPublishSources" => Huddle::PUBLISH_SOURCES + [ "camera" ] },
      { "canUpdateOwnMetadata" => true },
      { "unknownPrivilege" => true }
    ]

    privileged_grants.each do |privilege|
      claims = decoded_claims(@huddle.token)
      claims.fetch("video").merge!(privilege)
      post_authorize(signed_token(claims))
      assert_response :unauthorized
    end
  end

  test "malformed signed video grants receive a controlled denial" do
    claims = decoded_claims(@huddle.token).merge("video" => "not-an-object")

    post_authorize(signed_token(claims))

    assert_response :unauthorized

    claims = decoded_claims(@huddle.token)
    claims.fetch("video")["canPublishSources"] = [ "microphone", 1 ]
    post_authorize(signed_token(claims))

    assert_response :unauthorized
  end

  test "a valid token without an exact database grant is forbidden" do
    claims = decoded_claims(@huddle.token).merge("sub" => "campfire-participant-missing")

    post_authorize(signed_token(claims))

    assert_response :forbidden
  end

  test "a stale database link revokes the grant and is forbidden" do
    Membership.where(id: @huddle.grant.membership_id).delete_all

    post_authorize(@huddle.token)

    assert_response :forbidden
    assert @huddle.grant.reload.revoked?
    assert HuddleCleanup.exists?(operation: :remove_participant, huddle_grant_id: @huddle.grant_id)
  end

  test "grant lookup rechecks current access without requiring or rechecking the original token" do
    travel 5.minutes do
      get "/internal/huddle/grants/#{@huddle.grant_id}", headers: gateway_headers
    end

    assert_response :success
    assert_equal expected_payload, response.parsed_body
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "grant lookup returns not found after revocation" do
    @huddle.grant.revoke!

    get "/internal/huddle/grants/#{@huddle.grant_id}", headers: gateway_headers

    assert_response :not_found
  end

  test "gateway authentication is required for both endpoints" do
    post "/internal/huddle/authorize", headers: { "Authorization" => "Bearer #{@huddle.token}" }
    assert_response :unauthorized

    get "/internal/huddle/grants/#{@huddle.grant_id}", headers: { "X-Huddle-Gateway-Secret" => "wrong" }
    assert_response :unauthorized
  end

  test "internal endpoints fail closed when huddles are not fully configured" do
    ENV.delete("LIVEKIT_INTERNAL_URL")

    post_authorize(@huddle.token)

    assert_response :service_unavailable
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  private
    def post_authorize(token)
      post "/internal/huddle/authorize", headers: gateway_headers.merge("Authorization" => "Bearer #{token}")
    end

    def gateway_headers
      { "X-Huddle-Gateway-Secret" => "test-gateway-secret" }
    end

    def decoded_claims(token)
      JWT.decode(token, "test-api-secret", true, algorithm: "HS256").first
    end

    def signed_token(claims)
      JWT.encode(claims, "test-api-secret", "HS256")
    end

    def expected_payload
      {
        "grant_id" => @huddle.grant_id,
        "room_name" => @huddle.room_name,
        "identity" => @huddle.identity
      }
    end
end
