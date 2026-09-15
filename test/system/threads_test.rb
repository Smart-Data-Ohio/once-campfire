require "application_system_test_case"
require "fileutils"

class ThreadsTest < ApplicationSystemTestCase
  THREAD_SCREENSHOT_DIR = Rails.root.join("tmp/screenshots/thread-ux")

  setup do
    FileUtils.mkdir_p(THREAD_SCREENSHOT_DIR)
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  test "creates a thread from a channel message and keeps the channel draft separate" do
    thread_name = "Design review thread"
    first_message = "Let’s keep the design review focused here."

    create_thread_from_message(thread_name, first_message)
    assert_selector "#thread-panel [data-thread-panel-target='parent']", text: "Third time's a charm.", wait: 10
    assert_thread_message first_message

    thread = ChannelThread.find_by!(name: thread_name)
    find("#thread-panel [data-thread-panel-target='preferences'] summary").click
    find("#thread-panel [data-thread-panel-target='involvement'] option[value='nothing']").select_option
    wait_for_condition { thread.membership_for(users(:jz)).reload.involvement == "nothing" }

    find("#thread-panel [data-thread-panel-target='manage'] summary").click
    find("#thread-panel [data-thread-panel-target='autoArchive'] option[value='1440']").select_option
    wait_for_condition { thread.reload.auto_archive_after_minutes == 1_440 }

    fill_in "Write a message", with: "A channel draft stays here."
    within "#thread-panel" do
      fill_in "Write a thread reply", with: "A reply from the thread drawer."
      click_button "Send Reply"
    end

    assert_field "Write a message", with: "A channel draft stays here."
    assert_thread_message "A reply from the thread drawer."
    save_thread_screenshot "desktop-conversation.png"

    within_thread_message("A reply from the thread drawer.") do
      open_message_actions
      click_button "Reply"
    end
    assert_selector "#thread-panel [data-composer-target='contextLabel']", text: /Replying to/
    fill_in "Write a thread reply", with: "A reply to the drawer message."
    click_button "Send Reply"
    assert_selector "#thread-panel .message__reply-preview", text: /A reply from the thread drawer/, wait: 10

    within_thread_message(first_message) do
      open_message_actions
      assert_selector ".message__edit-action", visible: true, wait: 10
      click_button "Edit message"
    end
    assert_selector "#thread-panel [data-composer-target='contextLabel']", text: "Editing Message"
    fill_in "Write a thread reply", with: "The edited thread starter."
    click_button "Send Reply"
    assert_thread_message "The edited thread starter."
    assert_selector "#thread-panel [data-thread-panel-target='parent']", text: "Third time's a charm.", wait: 10

    within_thread_message("A reply to the drawer message.") do
      open_message_actions
      find(".message__quick-reaction[title='Thumbs up']").click
    end
    assert_selector "#thread-panel .boosts__reactions", text: "👍", wait: 10
  end

  test "browses active and closed threads and can join or leave a closed one" do
    active_name = "Active planning thread"
    closed_name = "Closed planning thread"

    create_thread_from_panel(active_name, "The active planning conversation.")
    close_threads

    using_session("David") do
      sign_in "david@37signals.com"
      join_room rooms(:designers)
      create_thread_from_panel(closed_name, "The closed planning conversation.")

      find("#thread-panel [data-thread-panel-target='manage'] summary").click
      assert_selector "#thread-panel [data-thread-panel-target='closeThread']", visible: true, wait: 10
      find("#thread-panel [data-thread-panel-target='closeThread']").click
      assert_selector "#thread-panel [data-thread-panel-target='threadStatus']", text: /Closed thread/, wait: 10
      close_threads
    end

    open_threads
    assert_selector "#thread-panel [data-thread-panel-target='browser']", visible: true
    assert_selector "#thread-panel [data-thread-panel-target='browserList'] .thread-panel__thread-item", text: active_name, wait: 10
    assert_no_selector "#thread-panel [data-thread-panel-target='browserList'] .thread-panel__thread-item", text: closed_name

    find("#thread-panel [data-thread-panel-target='filter'] option[value='closed']").select_option
    assert_selector "#thread-panel [data-thread-panel-target='browserList'] .thread-panel__thread-item", text: closed_name, wait: 10
    find("#thread-panel [data-thread-panel-target='browserList'] .thread-panel__thread-item", text: closed_name).click

    assert_selector "#thread-panel [data-thread-panel-target='conversation']", visible: true, wait: 10
    assert_selector "#thread-panel [data-thread-panel-target='join']", visible: true
    assert_no_selector "#thread-panel [data-thread-panel-target='leave']", visible: true

    click_button "Join"
    assert_selector "#thread-panel [data-thread-panel-target='leave']", visible: true, wait: 10
    assert_no_selector "#thread-panel [data-thread-panel-target='join']", visible: true

    click_button "Leave"
    assert_selector "#thread-panel [data-thread-panel-target='join']", visible: true, wait: 10
    assert_no_selector "#thread-panel [data-thread-panel-target='leave']", visible: true
  end

  test "keeps the thread drawer usable on a phone and preserves the channel" do
    create_thread_from_panel("Mobile thread", "The mobile thread starter.")
    close_threads

    page.current_window.resize_to(390, 844)
    open_threads
    assert_selector "#thread-panel[aria-hidden='false']", visible: true
    assert_selector "button[aria-label='Close threads']:focus"
    assert page.evaluate_script("document.querySelector('#thread-panel').contains(document.activeElement)"), "focus should stay in the thread drawer"

    assert_selector "#thread-panel [data-thread-panel-target='browserList'] .thread-panel__thread-item", text: "Mobile thread", wait: 10
    find("#thread-panel [data-thread-panel-target='browserList'] .thread-panel__thread-item", text: "Mobile thread").click
    assert_selector "#thread-panel [data-thread-panel-target='conversation']", visible: true, wait: 10
    click_button "Back to thread list"
    assert_selector "#thread-panel [data-thread-panel-target='browser']", visible: true
    click_button "New thread"
    assert_selector "#thread-panel [data-thread-panel-target='create']", visible: true
    fill_in "Thread name", with: "Mobile second thread"
    fill_in "First message", with: "A second mobile thread."
    find("#thread-panel [data-thread-panel-target='createSubmit']").click
    assert_selector "#thread-panel [data-thread-panel-target='conversation']", visible: true, wait: 10

    within_thread_message("A second mobile thread.") do
      open_message_actions
      assert page.evaluate_script(<<~JS), "the mobile message menu should stay inside the viewport"
        (() => {
          const menu = document.querySelector("#thread-panel .message__actions-menu:not([hidden])");
          if (!menu) return false;
          const rect = menu.getBoundingClientRect();
          return rect.left >= 0 && rect.top >= 0 && rect.right <= innerWidth && rect.bottom <= innerHeight;
        })()
      JS
    end

    page.send_keys :escape
    assert_selector "#thread-panel[aria-hidden='false']", visible: true
    save_thread_screenshot "mobile-drawer.png"
    click_button "Close threads"
    assert_no_selector "body.thread-panel-open"
    assert_selector "[data-thread-panel-target='browserToggle']:focus"
    assert_selector ".room-header__name", text: "Designers"
    assert_no_horizontal_overflow
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "marks a joined thread read only while the conversation is visible" do
    thread_name = "Unread thread coverage"
    create_thread_from_panel(thread_name, "The first unread check.")
    thread = ChannelThread.find_by!(name: thread_name)
    membership = ThreadMembership.find_by!(thread:, user: users(:jz))
    membership.update!(involvement: "everything", unread_at: nil)

    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
      open_threads
      find("#thread-panel [data-thread-panel-target='browserList'] .thread-panel__thread-item", text: thread_name).click
      assert_selector "#thread-panel [data-thread-panel-target='join']", visible: true, wait: 10
      click_button "Join"
      assert_selector "#thread-panel [data-thread-panel-target='leave']", visible: true, wait: 10
      fill_in "Write a thread reply", with: "A visible second-user reply."
      click_button "Send Reply"
    end

    assert_thread_message "A visible second-user reply."
    wait_for_thread_read_state(membership, unread: false)

    close_threads
    using_session("Kevin") do
      fill_in "Write a thread reply", with: "A hidden second-user reply."
      click_button "Send Reply"
    end
    wait_for_thread_read_state(membership, unread: true)

    open_threads
    assert_selector "#thread-panel [data-thread-panel-target='browserList'] .thread-panel__thread-item[data-unread='true']", text: thread_name, wait: 10
  end

  test "rejects an external thread deep link before fetching it" do
    external_url = "https://attacker.invalid/rooms/1/threads/999"
    visit "#{room_url(rooms(:designers))}?thread=#{ERB::Util.url_encode(external_url)}"

    assert_selector "#thread-panel[aria-hidden='false']", visible: true, wait: 10
    assert_selector "#thread-panel [data-thread-panel-target='threadStatus']", text: "This thread link is invalid."
    assert page.evaluate_script(<<~JS), "the browser must not request the external thread URL"
      !performance.getEntriesByType("resource").some(entry => entry.name.startsWith("https://attacker.invalid/"))
    JS
    assert_no_selector "#thread-panel .thread-panel__thread-content .message"
  end

  test "renders untrusted thread metadata as text" do
    malicious_name = %(<img src=x onerror="window.__threadXss = true">)

    create_thread_from_panel(malicious_name, "A safe thread body.")

    assert_selector "#thread-panel [data-thread-panel-target='conversationTitle']", text: malicious_name
    assert_no_selector "#thread-panel [data-thread-panel-target='conversationTitle'] img"
    assert_nil page.evaluate_script("window.__threadXss")
  end

  test "opens a shared thread message link around an older post" do
    room = rooms(:designers)
    thread = ChannelThread.create!(room:, creator: users(:jz), name: "Shared anchor thread")
    ThreadMembership.join!(thread, users(:jz))
    messages = (Message::PAGE_SIZE * 2 + 5).times.map do |index|
      Message.create!(
        room:,
        thread:,
        creator: users(:jz),
        markdown_source: "Shared anchor post #{index}",
        client_message_id: "shared-anchor-#{index}"
      )
    end
    anchor = messages.fetch(5)

    visit room_url(room, thread: thread.id, message_id: anchor.id)
    wait_for_thread_conversation(thread.name)
    assert_thread_message "Shared anchor post 5"
    assert_selector ".thread-panel__thread-content .message-area[data-messages-anchor-message-id-value='#{anchor.id}']"
    assert_selector ".thread-panel__thread-content .message-area__return-to-latest", visible: true, wait: 10
    assert page.evaluate_script(<<~JS), "an anchored thread should start away from the latest page"
      (() => {
        const messageArea = document.querySelector(".thread-panel__thread-content .message-area");
        return messageArea && messageArea.dataset.messagesAnchorMessageIdValue === "#{anchor.id}";
      })()
    JS
    save_thread_screenshot "shared-anchor.png"
  end

  test "keeps an anchored older thread unread when a new reply arrives" do
    room = rooms(:designers)
    thread = ChannelThread.create!(room:, creator: users(:jz), name: "Anchored unread race")
    ThreadMembership.join!(thread, users(:jz))

    anchor_index = 5
    message_count = Message::PAGE_SIZE * 3 + 1
    first_created_at = message_count.seconds.ago
    messages = message_count.times.map do |index|
      Message.create!(
        room:,
        thread:,
        creator: users(:jz),
        markdown_source: "Anchored race post #{index}",
        client_message_id: "anchored-race-#{index}",
        created_at: first_created_at + index.seconds
      )
    end
    anchor = messages.fetch(anchor_index)
    membership = ThreadMembership.find_by!(thread:, user: users(:jz))
    membership.update!(unread_at: nil)

    visit room_url(room, thread: thread.id, message_id: anchor.id)
    wait_for_thread_conversation(thread.name)
    assert_selector "#thread-panel turbo-cable-stream-source[connected]", visible: false, wait: 10
    assert_selector ".thread-panel__thread-content .messages[data-messages-at-latest='false']", wait: 10

    page.execute_script <<~JS
      const messages = document.querySelector("#thread-panel .thread-panel__thread-content .messages");
      messages.scrollTop = messages.scrollHeight;
      messages.dispatchEvent(new Event("scroll", { bubbles: true }));
    JS
    assert_thread_message "Anchored race post #{anchor_index + Message::PAGE_SIZE * 2}"
    assert_selector ".thread-panel__thread-content .messages[data-messages-at-latest='false']", wait: 10

    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room room
      visit room_url(room, thread: thread.id)
      wait_for_thread_conversation(thread.name)
      click_button "Join" if page.has_button?("Join", wait: 0)
      assert_selector "#thread-panel [data-thread-panel-target='leave']", visible: true, wait: 10
      fill_in "Write a thread reply", with: "A reply during the anchored page."
      click_button "Send Reply"
    end

    assert_no_selector "#thread-panel .thread-panel__thread-content .message__body", text: "A reply during the anchored page.", wait: 1
    assert_selector ".thread-panel__thread-content .messages[data-messages-at-latest='false']", wait: 10
    wait_for_thread_read_state(membership, unread: true)

    find("#thread-panel .message-area__return-to-latest", visible: true).click
    assert_selector ".thread-panel__thread-content .messages[data-messages-at-latest='true']", wait: 10
    assert_thread_message "A reply during the anchored page."
    wait_for_thread_read_state(membership, unread: false)
  end

  private
    def open_threads
      find("[data-thread-panel-target='browserToggle']").click unless page.has_css?("body.thread-panel-open", wait: 0)
      assert_selector "#thread-panel[aria-hidden='false']", visible: true, wait: 10
    end

    def close_threads
      click_button "Close threads" if page.has_css?("body.thread-panel-open", wait: 0)
      assert_no_selector "body.thread-panel-open", wait: 10
    end

    def create_thread_from_message(name, first_message)
      within_message(messages(:third)) do
        find("[data-message-edit-format], [data-reply-target='body']", match: :first).right_click
        assert_selector "[data-message-actions-target='menu']", visible: true, wait: 10
        click_button "Create thread"
      end

      assert_selector "#thread-panel [data-thread-panel-target='create']", visible: true, wait: 10
      fill_in "Thread name", with: name
      fill_in "First message", with: first_message
      find("#thread-panel [data-thread-panel-target='createSubmit']").click
      wait_for_thread_conversation(name)
    end

    def create_thread_from_panel(name, first_message)
      open_threads
      click_button "New thread"
      assert_selector "#thread-panel [data-thread-panel-target='create']", visible: true, wait: 10
      fill_in "Thread name", with: name
      fill_in "First message", with: first_message
      find("#thread-panel [data-thread-panel-target='createSubmit']").click
      wait_for_thread_conversation(name)
    end

    def wait_for_thread_conversation(name)
      assert_selector "#thread-panel [data-thread-panel-target='conversation']", visible: true, wait: 10
      assert_selector "#thread-panel [data-thread-panel-target='conversationTitle']", text: name, wait: 10
    end

    def assert_thread_message(text)
      assert_selector "#thread-panel .thread-panel__thread-content .message__body", text: text, wait: 10
    end

    def within_thread_message(text, &block)
      message = find("#thread-panel .thread-panel__conversation .message[data-message-id]", text: text, wait: 10)
      message_id = message["id"]
      assert_selector "##{message_id}[aria-haspopup='menu']", visible: false, wait: 10
      within(message) do
        assert_selector "[data-controller~='message-actions']", wait: 10
        yield
      end
    end

    def open_message_actions
      find("[data-message-edit-format], [data-reply-target='body']", match: :first).right_click
      assert_selector "[data-message-actions-target='menu']", visible: true, wait: 10
    end

    def wait_for_thread_read_state(membership, unread:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until membership.reload.unread? == unread
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
      assert_equal unread, membership.reload.unread?, "expected thread membership unread=#{unread}"
    end

    def wait_for_condition(timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
      assert yield
    end

    def save_thread_screenshot(name)
      page.save_screenshot THREAD_SCREENSHOT_DIR.join(name)
    end

    def assert_no_horizontal_overflow
      assert page.evaluate_script("document.documentElement.scrollWidth <= innerWidth + 1"), "the workspace overflows the viewport horizontally"
    end
end
