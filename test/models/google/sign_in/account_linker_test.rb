require "test_helper"

class Google::SignIn::AccountLinkerTest < ActiveSupport::TestCase
  include GoogleSignInTestHelper
  include GoogleCalendarTestHelper

  test "subject collision through a lost race still resolves to the subject owner" do
    owner = User.create!(name: "Owner", email_address: "owner@smartdata.net", password: "secret123456")
    GoogleIdentity.create!(user: owner, subject: "google-sub-race", email: "owner@smartdata.net", domain: "smartdata.net")
    other = User.create!(name: "Other", email_address: "other@smartdata.net", password: "secret123456")

    # Subject S belongs to owner, but the verified email now belongs to
    # other: the unique subject constraint fires, and the rescue
    # re-resolves by immutable subject instead of duplicating.
    user = Google::SignIn::AccountLinker.resolve!(
      { "sub" => "google-sub-race", "email" => "other@smartdata.net", "hd" => "smartdata.net" }
    )

    assert_equal owner.id, user.id
    assert_equal owner.id, GoogleIdentity.find_by!(subject: "google-sub-race").user_id
  end

  test "deactivated predecessor match escapes LIKE wildcards" do
    plain = User.create!(name: "Plain", email_address: "abc@smartdata.net", password: "secret123456")
    plain.deactivate

    # Without escaping, "_" would match "abc" and wrongly refuse a new user.
    user = Google::SignIn::AccountLinker.resolve!(
      { "sub" => "google-sub-underscore", "email" => "a_c@smartdata.net", "hd" => "smartdata.net" }
    )

    assert_equal "a_c@smartdata.net", user.email_address

    tricky = User.create!(name: "Tricky", email_address: "100%@smartdata.net", password: "secret123456")
    tricky.deactivate

    error = assert_raises(Google::SignIn::Rejected) do
      Google::SignIn::AccountLinker.resolve!(
        { "sub" => "google-sub-tricky", "email" => "100%@smartdata.net", "hd" => "smartdata.net" }
      )
    end

    assert_equal :deactivated, error.reason
    assert_not User.exists?(email_address: "100%@smartdata.net")
  end

  test "provisioned name falls back from claims to the email local part" do
    user = Google::SignIn::AccountLinker.resolve!(
      { "sub" => "google-sub-noname", "email" => "noname@smartdata.net", "hd" => "smartdata.net" }
    )
    assert_equal "noname", user.name

    named = Google::SignIn::AccountLinker.resolve!(
      { "sub" => "google-sub-named", "email" => "named@smartdata.net", "hd" => "smartdata.net",
        "given_name" => "Given", "family_name" => "Family" }
    )
    assert_equal "Given Family", named.name
  end
end
