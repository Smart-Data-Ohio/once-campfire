require "application_system_test_case"

class DriveLinkPreviewsTest < ApplicationSystemTestCase
  include GoogleCalendarTestHelper

  FILE_ID = "1AbcDefGhIjKlMnOpQrSt"
  DOCS_URL = "https://docs.google.com/document/d/#{FILE_ID}/edit"

  setup do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  teardown do
    WebMock.reset!
    WebMock.disable!
  end

  test "a viewer with the Drive scope sees the link upgraded to a preview chip" do
    connect_google!(users(:jz), scopes: DRIVE_SCOPES)
    stub_google_drive_file(FILE_ID)
    sign_in "jz@37signals.com"
    join_room rooms(:designers)

    send_message "Please review #{DOCS_URL} before Friday"

    assert_selector ".drive-chip__name", text: "Q3 Planning"
    assert_selector ".drive-chip__meta", text: /Modified.+Riel/
    assert_selector ".drive-chip__icon svg"
  end

  test "a viewer without the Drive scope keeps the plain link and fetches nothing" do
    sign_in "kevin@37signals.com"
    join_room rooms(:designers)
    install_fetch_recorder

    send_message "Please review #{DOCS_URL} before Friday"

    assert_message_text "Please review"
    assert_no_selector ".drive-chip"
    drive_requests = page.evaluate_script(
      "window.driveFetchUrls.filter(url => url.includes('/google/drive/files'))"
    )
    assert_empty drive_requests
  end

  test "composer Drive picker inserts the chosen file link at the caret" do
    connect_google!(users(:jz), scopes: DRIVE_SCOPES)
    stub_google_drive_list
    sign_in "jz@37signals.com"
    join_room rooms(:designers)

    fill_in_markdown "message_markdown_source", with: "see brief"
    page.execute_script(<<~JS)
      const editor = document.getElementById("message_markdown_source")
      editor.setSelectionRange(4, 4)
      editor.focus()
    JS

    find("button.composer__drive-btn").click

    assert_selector '[role="dialog"][aria-label="Find a Drive file"]'
    assert_selector ".drive-picker__item", text: "Q3 Planning"

    fill_in "Search Drive files", with: "plan"

    assert_selector ".drive-picker__item", text: "Q3 Planning"
    assert_selector ".drive-picker__meta", text: /Modified.+Riel/
    assert_selector ".drive-picker__icon svg"

    find_field("Search Drive files").send_keys(:down)

    assert_selector ".drive-picker__item--active", text: "Q3 Planning"

    find(".drive-picker__item", text: "Q3 Planning").click

    assert_equal "see https://docs.google.com/document/d/1AbcDefGhIjKlMnOpQrSt/edit brief",
      find_field("message_markdown_source").value
    assert_no_selector '[role="dialog"][aria-label="Find a Drive file"]'
  end

  test "composer omits the Drive button without the Drive scope" do
    sign_in "kevin@37signals.com"
    join_room rooms(:designers)

    assert_no_selector "button.composer__drive-btn"
  end

  private
    def install_fetch_recorder
      page.execute_script <<~JS
        window.driveFetchUrls = [];
        if (!window.driveFetchWrapped) {
          window.driveFetchWrapped = true;
          const originalFetch = window.fetch.bind(window);
          window.fetch = (url, options) => {
            window.driveFetchUrls.push(String((url && url.url) || url));
            return originalFetch(url, options);
          };
        }
      JS
    end
end
