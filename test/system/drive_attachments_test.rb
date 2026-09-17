require "application_system_test_case"

class DriveAttachmentsTest < ApplicationSystemTestCase
  include GoogleCalendarTestHelper

  FILE_ID = "1AbcDefGhIjKlMnOpQrSt"
  FILE_TWO = "2BcdEfgHiJkLmNoPqRsTu"

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

    within('[role="dialog"][aria-label="Find a Drive file"]') do
      assert_selector 'li[role="presentation"] > button[role="option"]'
      assert_selector 'li[role="presentation"] > button.drive-picker__attach'
      assert_no_selector '[role="option"] button'
    end

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

    # The message is textless, so dropping its only attachment needs replacement text.
    fill_in "Message", with: "the file moved elsewhere"
    click_on "Remove Google Drive file"
    assert_no_selector ".drive-attachment-chip"

    click_on "Save changes"
    assert_no_selector "a.drive-attachment"
    assert_empty Message.last.drive_attachments
  end

  test "edit a room message in the composer and remove one of two attachments" do
    connect_google!(users(:jz), scopes: DRIVE_SCOPES)
    stub_google_drive_list
    stub_google_drive_file(FILE_ID)
    stub_google_drive_file(FILE_TWO, body: drive_file_payload(name: "Budget 2026", mime_type: "application/vnd.google-apps.spreadsheet"))
    sign_in "jz@37signals.com"
    join_room rooms(:designers)

    find("button.composer__drive-btn").click
    attach_from_picker "Q3 Planning"
    find("button.composer__drive-btn").click
    attach_from_picker "Budget 2026"
    fill_in "Write a message", with: "two files attached"
    click_on "Send Message"

    assert_selector "a.drive-attachment", count: 2
    assert_selector ".drive-attachments .drive-chip__name", text: "Q3 Planning"
    assert_selector ".drive-attachments .drive-chip__name", text: "Budget 2026"

    within_message(Message.last) do
      open_message_actions
      click_button "Edit message"
    end

    assert_selector "[data-composer-target='contextLabel']", text: "Editing Message", wait: 10
    assert_selector ".composer__drive-attachments .drive-attachment-chip", count: 2
    within_chip("Budget 2026") { find("button").click }
    assert_selector ".composer__drive-attachments .drive-attachment-chip", count: 1
    click_on "Send Message"

    assert_selector "a.drive-attachment", count: 1
    assert_selector "a.drive-attachment[href='https://drive.google.com/open?id=#{FILE_ID}']"
    assert_selector "[data-composer-target='context'][hidden]", visible: false
    assert_equal [ FILE_ID ], Message.last.drive_attachments.map(&:file_id)
  end

  test "attach a Drive file from the thread composer" do
    connect_google!(users(:jz), scopes: DRIVE_SCOPES)
    stub_google_drive_list
    stub_google_drive_file(FILE_ID)
    sign_in "jz@37signals.com"

    room = rooms(:designers)
    thread = ChannelThread.create!(room:, creator: users(:jz), name: "Drive thread")
    ThreadMembership.join!(thread, users(:jz))
    join_room room
    visit room_url(room, thread: thread.id)

    assert_selector "#thread-panel [data-thread-panel-target='conversation']", visible: true, wait: 10
    within("#thread-panel") do
      find("button.composer__drive-btn").click
      assert_selector ".drive-picker__item", text: "Q3 Planning"
      attach_from_picker "Q3 Planning"
      assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
      fill_in "Write a thread reply", with: "thread file attached"
      click_button "Send Reply"
    end

    assert_selector "#thread-panel a.drive-attachment[href='https://drive.google.com/open?id=#{FILE_ID}']", wait: 10
    assert_equal [ FILE_ID ], thread.messages.order(:id).last.drive_attachments.map(&:file_id)
  end

  private
    def open_message_actions
      find("[data-message-edit-format], [data-reply-target='body']", match: :first).right_click
      assert_selector "[data-message-actions-target='menu']", visible: true, wait: 10
    end

    def attach_from_picker(name)
      item = find(".drive-picker__item", text: name)
      item.hover
      item.find("button.drive-picker__attach").click
    end

    def within_chip(name, &block)
      within find(".drive-attachment-chip", text: name), &block
    end
end
