require "test_helper"

class ActivityItemsHelperTest < ActionView::TestCase
  include ActivityItemsHelper

  test "review request label" do
    item = ActivityItem.new(event_type: "pr_review_request")

    assert_equal "Review requested", activity_item_event_label(item)
  end
end
