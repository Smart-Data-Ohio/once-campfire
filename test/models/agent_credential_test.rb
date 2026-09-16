require "test_helper"

class AgentCredentialTest < ActiveSupport::TestCase
  test "create_with_secret stores a digest and returns a reveal-once secret" do
    credential, secret = AgentCredential.create_with_secret!(
      agent: agents(:bender_agent),
      name: "CI runner",
      created_by: users(:david)
    )

    assert secret.present?
    assert_equal 64, secret.length
    assert_equal Digest::SHA256.hexdigest(secret), credential.token_digest
    assert_equal secret[-4..], credential.token_last_four
    assert credential.active?
  end

  test "name is required" do
    assert_raises ActiveRecord::RecordInvalid do
      AgentCredential.create_with_secret!(
        agent: agents(:bender_agent),
        name: "",
        created_by: users(:david)
      )
    end
  end

  test "token digest is unique" do
    existing = agent_credentials(:bender_main)

    duplicate = AgentCredential.new(
      agent: agents(:bender_agent),
      name: "Duplicate",
      created_by: users(:david),
      token_digest: existing.token_digest,
      token_last_four: "1234"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:token_digest], "has already been taken"
  end

  test "authenticate finds an active credential and ignores whitespace" do
    credential = AgentCredential.authenticate("  bender-test-secret-1234  ")

    assert_equal agent_credentials(:bender_main), credential
  end

  test "authenticate returns nil for unknown secrets" do
    assert_nil AgentCredential.authenticate("no-such-secret")
    assert_nil AgentCredential.authenticate("")
    assert_nil AgentCredential.authenticate(nil)
  end

  test "revoked credentials do not authenticate" do
    credential = agent_credentials(:bender_main)
    credential.revoke!

    assert credential.revoked?
    assert_not credential.active?
    assert_nil AgentCredential.authenticate("bender-test-secret-1234")
  end

  test "expired credentials do not authenticate" do
    credential = agent_credentials(:bender_main)
    credential.update!(expires_at: 1.minute.ago)

    assert credential.expired?
    assert_not credential.active?
    assert_nil AgentCredential.authenticate("bender-test-secret-1234")
  end

  test "future expiry stays active" do
    credential = agent_credentials(:bender_main)
    credential.update!(expires_at: 1.day.from_now)

    assert_not credential.expired?
    assert credential.active?
    assert_equal credential, AgentCredential.authenticate("bender-test-secret-1234")
  end

  test "record_use stamps time and ip" do
    credential = agent_credentials(:bender_main)

    assert_nil credential.last_used_at

    credential.record_use!("203.0.113.7")
    credential.reload

    assert_in_delta Time.current, credential.last_used_at, 5.seconds
    assert_equal "203.0.113.7", credential.last_used_ip
  end

  test "destroying the agent removes its credentials" do
    credential_id = agent_credentials(:bender_main).id
    agents(:bender_agent).destroy!

    assert_not AgentCredential.exists?(credential_id)
  end
end
