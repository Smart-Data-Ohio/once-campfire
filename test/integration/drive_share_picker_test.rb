require "test_helper"

class DriveSharePickerTest < ActionDispatch::IntegrationTest
  include GoogleCalendarTestHelper

  setup do
    @picker_env_before_test = [ ENV["GOOGLE_PICKER_API_KEY"], ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] ]
    sign_in :david
    @room = users(:david).rooms.last
  end

  teardown do
    ENV["GOOGLE_PICKER_API_KEY"], ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = @picker_env_before_test
  end

  test "composer carries a single enhanced Drive button when sharing is configured" do
    configure_picker!

    get room_url(@room)

    assert_response :success
    assert_includes response.body, '<meta name="google-drive-share" content="enabled">'
    assert_includes response.body, '<meta name="google-picker-client-id" content="test-client-id">'
    assert_includes response.body, '<meta name="google-picker-api-key" content="test-picker-key">'
    assert_includes response.body, '<meta name="google-cloud-project-number" content="123456789012">'
    assert_select '[data-controller="drive-share"]', count: 1
    assert_select "button.composer__drive-btn", text: "Drive", count: 1
    assert_select '[data-controller="drive-picker"]', count: 0
  end

  test "enhanced button needs no Drive consent and wins over the legacy picker" do
    configure_picker!
    connect_google!(users(:david), scopes: DRIVE_SCOPES)

    get room_url(@room)

    assert_response :success
    assert_select '[data-controller="drive-share"]', count: 1
    assert_select '[data-controller="drive-picker"]', count: 0
    assert_includes response.body, '<meta name="google-drive-previews" content="enabled">'
  end

  test "composer falls back to the legacy picker when sharing is not configured" do
    connect_google!(users(:david), scopes: DRIVE_SCOPES)

    get room_url(@room)

    assert_response :success
    assert_not_includes response.body, "google-drive-share"
    assert_select '[data-controller="drive-share"]', count: 0
    assert_select '[data-controller="drive-picker"]', count: 1
  end

  test "composer omits every Drive button without sharing or Drive consent" do
    get room_url(@room)

    assert_response :success
    assert_not_includes response.body, "google-drive-share"
    assert_select '[data-controller="drive-share"]', count: 0
    assert_select '[data-controller="drive-picker"]', count: 0
  end

  test "signed-out visitors see no share metas or buttons" do
    configure_picker!
    delete session_path

    get room_url(@room)

    assert_redirected_to new_session_url
  end

  private
    def configure_picker!
      ENV["GOOGLE_PICKER_API_KEY"] = "test-picker-key"
      ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = "123456789012"
    end
end
