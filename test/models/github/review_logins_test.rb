require "test_helper"

class Github::ReviewLoginsTest < ActiveSupport::TestCase
  test "splits on commas and whitespace, strips @, downcases, and dedupes" do
    assert_equal %w[ alice bob ],
      Github::ReviewLogins.normalize(" @Alice, alice  @BOB,bob ")
  end

  test "accepts an array of tokens" do
    assert_equal %w[ alice bob ],
      Github::ReviewLogins.normalize([ "@Alice", "bob, alice" ])
  end

  test "blank input normalizes to an empty array" do
    assert_equal [], Github::ReviewLogins.normalize("  ")
    assert_equal [], Github::ReviewLogins.normalize(nil)
    assert_equal [], Github::ReviewLogins.normalize([])
  end

  test "invalid logins normalize to nil" do
    assert_nil Github::ReviewLogins.normalize("alice, bob!!")
    assert_nil Github::ReviewLogins.normalize("-alice")
    assert_nil Github::ReviewLogins.normalize("a" * 40)
  end

  test "more than 15 unique logins normalizes to nil" do
    fifteen = (1..15).map { |index| "user#{index}" }.join(", ")
    sixteen = "#{fifteen}, user16"

    assert_equal 15, Github::ReviewLogins.normalize(fifteen).size
    assert_nil Github::ReviewLogins.normalize(sixteen)
  end
end
