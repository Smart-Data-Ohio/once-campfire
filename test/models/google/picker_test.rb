require "test_helper"

class Google::PickerTest < ActiveSupport::TestCase
  setup do
    @env_before_test = [ ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_PICKER_API_KEY"], ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] ]
  end

  teardown do
    ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_PICKER_API_KEY"], ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = @env_before_test
  end

  test "configured only when all three public values are present" do
    ENV["GOOGLE_CLIENT_ID"] = "test-client-id"
    ENV["GOOGLE_PICKER_API_KEY"] = "test-picker-key"
    ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = "123456789012"

    assert Google::Picker.configured?

    ENV.delete("GOOGLE_PICKER_API_KEY")
    assert_not Google::Picker.configured?

    ENV["GOOGLE_PICKER_API_KEY"] = "test-picker-key"
    ENV.delete("GOOGLE_CLOUD_PROJECT_NUMBER")
    assert_not Google::Picker.configured?

    ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = "123456789012"
    ENV.delete("GOOGLE_CLIENT_ID")
    assert_not Google::Picker.configured?
  end

  test "blank values count as missing" do
    ENV["GOOGLE_CLIENT_ID"] = "test-client-id"
    ENV["GOOGLE_PICKER_API_KEY"] = "  "
    ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = "123456789012"

    assert_not Google::Picker.configured?
  end
end
