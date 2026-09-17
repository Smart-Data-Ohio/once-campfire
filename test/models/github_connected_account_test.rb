require "test_helper"

class GithubConnectedAccountTest < ActiveSupport::TestCase
  test "one account per user" do
    connect_github!(users(:david))

    duplicate = GithubConnectedAccount.new(user: users(:david), github_login: "other", access_token: "x")

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:user_id]
  end

  test "token is encrypted at rest" do
    account = connect_github!(users(:david))

    raw = GithubConnectedAccount.connection.select_value(
      "SELECT access_token FROM github_connected_accounts WHERE id = #{account.id}"
    )

    assert_not_equal "github-token-#{users(:david).id}", raw
    assert_equal "github-token-#{users(:david).id}", account.reload.access_token
  end

  test "an undecryptable token is unusable, not fatal" do
    account = connect_github!(users(:david))
    GithubConnectedAccount.connection.execute(
      "UPDATE github_connected_accounts SET access_token = 'bogus-ciphertext' WHERE id = #{account.id}"
    )

    assert_nothing_raised do
      assert_not account.reload.usable?
    end
    assert_not_predicate account, :connected?
    assert_equal "The stored token could not be read; link it again", account.disconnected_reason
    assert_not account.usable?
  end

  test "connected, usable, and disconnect reason" do
    account = connect_github!(users(:david))

    assert_predicate account, :connected?
    assert_predicate account, :usable?

    account.mark_disconnected!("GitHub rejected the token (401)")

    assert_not_predicate account, :connected?
    assert_not_predicate account, :usable?
    assert_equal "GitHub rejected the token (401)", account.disconnected_reason
  end

  private
    def connect_github!(user, **attributes)
      GithubConnectedAccount.create!(
        user:,
        github_login: user.name.parameterize,
        access_token: "github-token-#{user.id}",
        **attributes
      )
    end
end
