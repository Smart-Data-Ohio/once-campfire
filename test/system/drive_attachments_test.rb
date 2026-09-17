require "application_system_test_case"

class DriveAttachmentsTest < ApplicationSystemTestCase
  include GoogleCalendarTestHelper

  FILE_ID = "1AbcDefGhIjKlMnOpQrSt"

  setup do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  teardown do
    WebMock.reset!
    WebMock.disable!
  end

  # Same belt-and-suspenders as DriveLinkPreviewsTest: WebMock must never
  # leak out of this file, even when a test or an earlier teardown step
  # errors, or later system tests' chromedriver traffic breaks.
  def after_teardown
    super
  ensure
    WebMock.reset!
    WebMock.disable!
  end

  test "attach Drive files from the picker, send textless, and remove through edit" do
    connect_google!(users(:jz), scopes: DRIVE_SCOPES)
    stub_google_drive_list
    stub_google_drive_file(FILE_ID)
    sign_in "jz@37signals.com"
    join_room rooms(:designers)

    find("button.composer__drive-btn").click
    assert_selector ".drive-picker__item", text: "Q3 Planning"

    attach_from_picker "Q3 Planning"
    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
    assert_no_selector '[role="dialog"][aria-label="Find a Drive file"]'

    find("button.composer__drive-btn").click
    attach_from_picker "Budget 2026"
    assert_selector ".composer__drive-attachments .drive-attachment-chip", count: 2

    # Dropping a pending chip keeps it out of the sent message.
    within_chip("Budget 2026") { find("button").click }
    assert_selector ".composer__drive-attachments .drive-attachment-chip", count: 1

    click_on "Send Message"

    assert_no_selector ".composer__drive-attachments .drive-attachment-chip"
    assert_selector "a.drive-attachment[href='https://drive.google.com/open?id=#{FILE_ID}']"
    assert_selector ".drive-attachments .drive-chip__name", text: "Q3 Planning"
    assert_equal [ FILE_ID ], Message.last.drive_attachments.map(&:file_id)

    visit edit_room_message_path(rooms(:designers), Message.last)
    assert_selector ".drive-attachment-chip", text: "Google Drive file"

    click_on "Remove Google Drive file"
    assert_no_selector ".drive-attachment-chip"

    click_on "Save changes"
    assert_no_selector "a.drive-attachment"
    assert_empty Message.last.drive_attachments
  end

  private
    def attach_from_picker(name)
      item = find(".drive-picker__item", text: name)
      item.hover
      item.find("button.drive-picker__attach").click
    end

    def within_chip(name, &block)
      within find(".drive-attachment-chip", text: name), &block
    end
end
