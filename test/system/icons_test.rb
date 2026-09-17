require "application_system_test_case"

class IconsTest < ApplicationSystemTestCase
  setup do
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    page.current_window.resize_to(1440, 1000)
    emulate_theme "light"
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
    page.current_window.resize_to(1400, 1400)
    emulate_theme "light"
  end

  test "colon autocomplete inserts a brand shortcode that renders in both themes" do
    assert_selector "meta[name='brand-icon-names'][content*='openai']", visible: false

    editor = find_field("Write a message")

    editor.set "::"
    sleep 0.5
    assert_no_selector "suggestion-option"

    editor.set "12:30"
    sleep 0.5
    assert_no_selector "suggestion-option"

    editor.set "http://"
    sleep 0.5
    assert_no_selector "suggestion-option"

    editor.set ":open"
    assert_selector "suggestion-option", text: "OpenAI"
    editor.send_keys :enter
    assert_field "Write a message", with: ":openai: "
    assert_not Message.exists?(markdown_source: ":openai: ")

    click_on "Send Message"
    assert_selector ".message img.icon--brand"
    message = Message.find_by!(markdown_source: ":openai: ")
    assert_selector "##{dom_id(message)}.message--emoji"
    within_message(message) { assert_selector "img.icon--brand" }
    assert_equal "none", icon_filter(message)

    emulate_theme "dark"
    assert page.evaluate_script("matchMedia('(prefers-color-scheme: dark)').matches")
    within_message(message) { assert_selector "img.icon--brand", visible: true }
    assert_equal "invert(1)", icon_filter(message)
  end

  test "room icon picker sets an icon that shows in the sidebar and header" do
    using_session("Admin") do
      sign_in "david@37signals.com"
      visit edit_rooms_open_path(rooms(:pets))

      fill_in "Icon", with: ":open"
      assert_selector "suggestion-option", text: "OpenAI"
      find("suggestion-option", text: "OpenAI").click
      assert_field "Icon", with: ":openai: "
      assert_selector "[data-icon-field-target='preview'] img.icon-avatar"

      find("button.btn--reversed").click
      assert_selector ".room-header__name", text: "All Pets"
      assert_selector ".room-header__identity img.icon-avatar"
      assert_selector "##{dom_id(rooms(:pets), :list)} .sidebar-item__icon--custom img.icon-avatar"
      assert_equal "none", sidebar_marker_content(rooms(:pets))
      assert_equal '"#"', sidebar_marker_content(rooms(:hq))
    end
  end

  test "icon rooms suppress the search arrow marker" do
    rooms(:designers).update!(icon_name: "openai")
    rooms(:designers).messages.create!(body: "Cartography atlas rendezvous", creator: users(:david), client_message_id: "icon-search-room")
    rooms(:hq).messages.create!(body: "Cartography ledger rendezvous", creator: users(:david), client_message_id: "plain-search-room")

    visit searches_path(q: "Cartography rendezvous")

    assert_selector "#search-results .message__room--custom img.icon-avatar"
    assert_selector "#search-results .message__room:not(.message__room--custom)"
    assert_equal "none", search_marker_content(".message__room--custom")
    assert_equal '"→"', search_marker_content(".message__room:not(.message__room--custom)")
  end

  test "lobehub brand icons render visibly in both themes" do
    editor = find_field("Write a message")
    editor.set "Ship :xai: and :microsoft: today"
    click_on "Send Message"
    assert_selector ".message img.icon--brand"

    message = Message.find_by!(markdown_source: "Ship :xai: and :microsoft: today")
    within_message(message) { assert_selector "img.icon--brand", count: 2 }
    assert_icon_rendered message, ":xai:"
    assert_icon_rendered message, ":microsoft:"
    assert_equal "none", icon_filter(message)

    emulate_theme "dark"
    assert page.evaluate_script("matchMedia('(prefers-color-scheme: dark)').matches")
    within_message(message) { assert_selector "img.icon--brand", count: 2, visible: true }
    assert_icon_rendered message, ":xai:"
    assert_icon_rendered message, ":microsoft:"
    assert_equal "invert(1)", icon_filter(message)
  end

  private
    def assert_icon_rendered(message, alt)
      width, height = page.evaluate_script(<<~JS, dom_id(message), alt)
        ((id, alt) => {
          const rect = document.querySelector(`#${id} img.icon--brand[alt="${alt}"]`).getBoundingClientRect();
          return [ rect.width, rect.height ];
        })(arguments[0], arguments[1])
      JS

      assert_operator width, :>, 0, "expected #{alt} to render with non-zero width"
      assert_operator height, :>, 0, "expected #{alt} to render with non-zero height"
    end

    def emulate_theme(theme)
      page.driver.browser.execute_cdp "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: theme } ]
    end

    def icon_filter(message)
      page.evaluate_script(<<~JS, dom_id(message))
        getComputedStyle(document.querySelector(`#${arguments[0]} img.icon--brand`)).filter
      JS
    end

    def sidebar_marker_content(room)
      page.evaluate_script(<<~JS, dom_id(room, :list))
        getComputedStyle(document.querySelector(`#${arguments[0]} .sidebar-item__icon`), "::before").content
      JS
    end

    def search_marker_content(selector)
      page.evaluate_script(<<~JS, selector)
        getComputedStyle(document.querySelector(`#search-results ${arguments[0]}`), "::before").content
      JS
    end
end
