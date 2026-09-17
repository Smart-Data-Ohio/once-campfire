require "application_system_test_case"

class WorkspaceIconsTest < ApplicationSystemTestCase
  setup do
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    page.current_window.resize_to(1440, 1000)
    emulate_theme "light"
    sign_in "david@37signals.com"
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
    emulate_theme "light"
  end

  test "upload post in both themes then delete falls back to the shortcode" do
    visit account_icons_path
    fill_in "workspace_icon_name", with: "acme"
    fill_in "workspace_icon_title", with: "Acme Corp"
    attach_file "workspace_icon_image", Rails.root.join("test/fixtures/files/workspace_icons/clean.svg")
    click_on "Upload icon"

    assert_selector "code", text: ":acme:"
    assert_selector "img[src='/icons/acme']"

    join_room rooms(:designers)
    send_message "Ship it with :acme: today"
    assert_selector "img.icon--custom[src='/icons/acme'][alt=':acme:']", visible: true
    message = Message.find_by!(markdown_source: "Ship it with :acme: today")

    within_message(message) do
      assert_selector "img.icon--custom[src='/icons/acme'][alt=':acme:']", visible: true
    end

    emulate_theme "dark"
    within_message(message) do
      assert_selector "img.icon--custom[src='/icons/acme']", visible: true
    end
    emulate_theme "light"

    visit account_icons_path
    accept_confirm do
      find("li", text: ":acme:").find("button[type='submit']").click
    end

    assert_no_selector "code", text: ":acme:"

    join_room rooms(:designers)
    within_message(message) do
      assert_no_selector "img.icon--custom", visible: :all
      assert_text "Ship it with :acme: today"
    end
  end

  private
    def emulate_theme(theme)
      page.driver.browser.execute_cdp "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: theme } ]
    end
end
