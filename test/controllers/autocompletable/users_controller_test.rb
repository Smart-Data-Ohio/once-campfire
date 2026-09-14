require "test_helper"

class Autocompletable::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "search returns matching users" do
    get autocompletable_users_url(format: :json), params: { query: "da" }

    assert_response :success
    assert_equal "David", response.parsed_body.first["name"]
  end

  test "search results escape HTML in names" do
    users(:david).update!(name: "David <script>alert(123)</script>")

    get autocompletable_users_url(format: :json), params: { query: "da" }

    assert_response :success
    assert_equal "David &lt;script&gt;alert(123)&lt;/script&gt;", response.parsed_body.first["name"]
  end

  test "room search returns matching users" do
    get autocompletable_users_url(room_id: rooms(:hq).id, format: :json), params: { query: "da" }

    assert_response :success
    assert_equal "David", response.parsed_body.first["name"]
    assert_equal "David", response.parsed_body.first["markdown_display_name"]
    assert_equal "@[David]", response.parsed_body.first["mention_token"]
  end

  test "room search omits the Markdown token for duplicate display names" do
    User.create!(name: "David")

    get autocompletable_users_url(room_id: rooms(:hq).id, format: :json), params: { query: "da" }

    assert_response :success
    david_results = response.parsed_body.select { |result| result["markdown_display_name"] == "David" }
    assert_equal 2, david_results.size
    assert david_results.all? { |result| !result.key?("mention_token") }
  end

  test "room search is scoped by membership" do
    sign_in :kevin

    assert_not_includes users(:kevin).rooms, rooms(:watercooler)

    assert_raises ActiveRecord::RecordNotFound do
      get autocompletable_users_url(room_id: rooms(:watercooler).id, format: :json), params: { query: "da" }
    end
  end
end
