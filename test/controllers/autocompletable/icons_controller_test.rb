require "test_helper"

class Autocompletable::IconsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "requires authentication like the users endpoint" do
    sign_out

    get autocompletable_icons_url(format: :json), params: { q: "open" }

    assert_redirected_to new_session_url
  end

  test "returns mixed brand and emoji matches with their payloads" do
    get autocompletable_icons_url(format: :json), params: { q: "open" }

    assert_response :success
    results = response.parsed_body

    openai = results.first
    assert_equal "openai", openai["name"]
    assert_equal "OpenAI", openai["title"]
    assert_equal "brand", openai["kind"]
    assert_match %r{\A/assets/icons/brands/openai-[a-z0-9]+\.svg\z}, openai["image"]
    assert_not openai.key?("character")

    emoji = results.find { |result| result["kind"] == "emoji" }
    assert emoji, "expected an emoji match in #{results.map { _1["name"] }}"
    assert emoji["character"].present?
    assert_not emoji.key?("image")
  end

  test "orders prefix matches first and limits the results" do
    get autocompletable_icons_url(format: :json), params: { q: "fire" }

    assert_response :success
    names = response.parsed_body.map { _1["name"] }

    assert_equal "fire", names.first
    assert_includes names, "heart_on_fire"
    assert_operator names.index("fire"), :<, names.index("heart_on_fire")
    assert_operator names.size, :<=, 8
  end

  test "returns no matches for blank or unknown queries" do
    get autocompletable_icons_url(format: :json), params: { q: "" }
    assert_equal [], response.parsed_body

    get autocompletable_icons_url(format: :json), params: { q: "zzz_no_such_icon" }
    assert_equal [], response.parsed_body
  end

  private
    def sign_out
      delete session_url
    end
end
