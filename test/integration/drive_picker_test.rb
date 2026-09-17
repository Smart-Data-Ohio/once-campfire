require "test_helper"

class DrivePickerTest < ActionDispatch::IntegrationTest
  include GoogleCalendarTestHelper

  setup do
    sign_in :david
    @room = users(:david).rooms.last
  end

  test "composer omits the Drive button without Drive consent" do
    get room_url(@room)

    assert_response :success
    assert_not_includes response.body, "google-drive-previews"
    assert_select '[data-controller="drive-picker"]', count: 0
    assert_select "button.composer__drive-btn", count: 0

    connect_google!(users(:david))

    get room_url(@room)

    assert_response :success
    assert_not_includes response.body, "google-drive-previews"
    assert_select '[data-controller="drive-picker"]', count: 0
  end

  test "composer carries the Drive button with the Drive scope" do
    connect_google!(users(:david), scopes: DRIVE_SCOPES)

    get room_url(@room)

    assert_response :success
    assert_includes response.body, '<meta name="google-drive-previews" content="enabled">'
    assert_select '[data-controller="drive-picker"]', count: 1
    assert_select "button.composer__drive-btn", text: "Drive"
    assert_select '.drive-picker__panel[role="dialog"][aria-label="Find a Drive file"]', count: 1
  end
end
