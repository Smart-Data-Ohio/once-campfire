require "application_system_test_case"
require "fileutils"

class ActivityInboxTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp/screenshots/activity-inbox")

  setup do
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    @item = ActivityItem.create!(user: users(:david), source: messages(:first), event_type: "mention")
    sign_in "david@37signals.com"
  end

  test "handles an item, clears the badge, and receives a later activity" do
    visit activity_items_url

    assert_selector "#activity-inbox-title", text: "Activity inbox"
    assert_selector "##{dom_id(@item)}"
    assert_selector ".workspace-activity-count", text: "1", wait: 10

    within "##{dom_id(@item)}" do
      click_button "Mark handled"
    end

    assert_selector "#activity-unread-count[hidden]", visible: :all, wait: 10
    assert_selector ".workspace-activity-count[hidden]", visible: :all, wait: 10
    assert_no_selector "#activity-unread-count", visible: true
    assert_no_selector ".workspace-activity-count", visible: true

    new_item = ActivityItem.create!(user: users(:david), source: messages(:second), event_type: "reply")

    assert_selector "##{dom_id(new_item)}", wait: 10
    assert_selector "#activity-unread-count", text: "1", wait: 10
    assert_selector ".workspace-activity-count", text: "1", wait: 10

    page.save_screenshot SCREENSHOT_DIR.join("desktop-populated.png")
    page.current_window.resize_to(390, 844)
    page.save_screenshot SCREENSHOT_DIR.join("mobile-populated.png")
  ensure
    page.current_window.resize_to(1400, 1400)
  end
end
