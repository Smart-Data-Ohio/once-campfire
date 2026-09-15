require "application_system_test_case"
require "fileutils"

class MessageInteractionsTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp/screenshots/message-ux")

  setup do
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    @room = rooms(:designers)
    sign_in "jz@37signals.com"
    join_room @room
  end

  test "opens message actions from context menu and keyboard, and cancels a moving long press" do
    within_message(messages(:third)) do
      open_message_actions
      assert_selector ".message__quick-reaction", count: EmojiHelper::REACTIONS.length
    end

    page.send_keys :escape
    assert_no_selector ".message[data-message-actions-open]"

    message = find("##{dom_id(messages(:third))}")
    message.click
    page.execute_script <<~JS, message
      arguments[0].dispatchEvent(new KeyboardEvent("keydown", {
        bubbles: true,
        cancelable: true,
        key: "F10",
        shiftKey: true
      }))
    JS
    assert_selector ".message[data-message-actions-open] .message__quick-reaction", visible: true
    page.send_keys :escape
    assert_selector "##{dom_id(messages(:third))}:focus"

    page.current_window.resize_to(390, 844)
    message = find("##{dom_id(messages(:third))}")
    perform_touch_gesture(message, move_by: [ 25, 0 ])
    assert_no_selector ".message[data-message-actions-open]"

    perform_touch_gesture(message)
    assert_selector ".message[data-message-actions-open] .message__quick-reaction", visible: true
    assert_menu_within_viewport
    page.execute_script "window.confirm = () => false"
    click_button "Delete message"
    assert_selector ".message[data-message-actions-open] .message__delete-action", visible: true
    assert_selector "##{dom_id(messages(:third))}"
    save_screenshot "mobile-long-press.png"
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "edits through the normal composer and restores the saved draft on cancel and success" do
    fill_in "Write a message", with: "A draft that must survive editing"

    within_message(messages(:third)) do
      open_message_actions
      click_button "Edit message"
    end

    assert_selector "[data-composer-target='contextLabel']", text: "Editing Message", wait: 10
    assert_field "Write a message", with: "Third time's a charm."
    save_screenshot "desktop-edit-context.png"
    click_button "Cancel message context"
    assert_field "Write a message", with: "A draft that must survive editing"

    within_message(messages(:third)) do
      open_message_actions
      click_button "Edit message"
    end
    fill_in "Write a message", with: "Saved through the main composer"
    click_button "Send Message"

    assert_selector ".message__body", text: "Saved through the main composer", wait: 10
    assert_selector "[data-composer-target='context'][hidden]", visible: false
    assert_field "Write a message", with: "A draft that must survive editing"
    save_screenshot "desktop-edit-composer.png"
  end

  test "keeps newer typing through an asynchronous edit and leaves failures in edit mode" do
    within_message(messages(:third)) do
      open_message_actions
      click_button "Edit message"
    end
    assert_selector "[data-composer-target='contextLabel']", text: "Editing Message", wait: 10
    fill_in "Write a message", with: "First edit request"

    page.execute_script <<~JS
      window.__messageInteractionsOriginalFetch = window.fetch
      window.fetch = (input, options = {}) => {
        if (options.method === "PATCH") {
          return new Promise(resolve => { window.__messageInteractionsResolveEdit = resolve })
        }
        return window.__messageInteractionsOriginalFetch(input, options)
      }
    JS

    click_button "Send Message"
    fill_in "Write a message", with: "A newer draft typed while saving"
    page.execute_script <<~JS
      window.__messageInteractionsResolveEdit(new Response("{}", { status: 200 }))
    JS

    assert_field "Write a message", with: "A newer draft typed while saving", wait: 10
    assert_selector "[data-composer-target='context'][hidden]", visible: false

    page.execute_script <<~JS
      window.fetch = (input, options = {}) => {
        if (options.method === "PATCH") {
          return Promise.resolve(new Response(JSON.stringify({ error: "The message could not be saved" }), {
            status: 422,
            headers: { "Content-Type": "application/json" }
          }))
        }
        return window.__messageInteractionsOriginalFetch(input, options)
      }
    JS

    within_message(messages(:third)) do
      open_message_actions
      click_button "Edit message"
    end
    fill_in "Write a message", with: "Failed edit"
    click_button "Send Message"
    assert_selector "[data-composer-target='feedback']", text: "The message could not be saved", visible: true, wait: 10
    assert_selector "[data-composer-target='context']", visible: true
    click_button "Cancel message context"
  ensure
    page.execute_script "window.fetch = window.__messageInteractionsOriginalFetch" if page
  end

  test "replies with notify off and renders a tombstone when the target is deleted" do
    within_message(messages(:third)) do
      open_message_actions
      click_button "Reply"
    end

    assert_selector "[data-composer-target='contextLabel']", text: /Replying to JZ/, wait: 10
    assert_field "Notify author", checked: true
    uncheck "Notify author"
    fill_in "Write a message", with: "A reply without a notification"
    click_button "Send Message"

    assert_selector ".message__reply-preview", text: /Replying to JZ/, wait: 10
    reply = @room.messages.find_by!(markdown_source: "A reply without a notification")
    assert_equal messages(:third).id, reply.reply_to_message_id
    assert_not reply.reply_notify_author?

    messages(:third).destroy!
    visit room_url(@room)
    assert_selector ".message__reply-preview", text: "Replying to a deleted message", wait: 10
  end

  test "copies message text and link and forwards to a server-provided thread destination" do
    destination_thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Forward destination")

    page.execute_script <<~JS
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: text => { window.__messageInteractionsCopied = text; return Promise.resolve() } }
      })
    JS

    within_message(messages(:third)) do
      open_message_actions
      click_button "Copy text"
    end
    assert_equal "Third time's a charm.", page.evaluate_script("window.__messageInteractionsCopied")

    within_message(messages(:third)) do
      open_message_actions
      click_button "Copy message link"
    end
    assert_includes page.evaluate_script("window.__messageInteractionsCopied"), "/rooms/#{@room.id}/@#{messages(:third).to_param}"

    within_message(messages(:third)) do
      open_message_actions
      click_button "Forward"
    end
    assert_selector "dialog[open]", visible: true, wait: 10
    find(".message-forward-dialog__destination", text: "Forward destination", wait: 10).click
    fill_in "Add a note", with: "Forwarded from the interaction test"
    within "dialog[open]" do
      click_button "Forward"
    end

    assert_selector "[data-message-actions-target='forwardStatus']", text: /Forwarded to 1 destination/, wait: 10
    assert Message.exists?(forward_note: "Forwarded from the interaction test", thread_id: destination_thread.id)
    save_screenshot "forward-dialog.png"
  end

  test "groups emoji reactions, updates the live count, and highlights the current user" do
    using_session("David") do
      sign_in "david@37signals.com"
      join_room @room

      within_message(messages(:third)) do
        open_message_actions
        find(".message__quick-reaction[title='Thumbs up']").click
      end

      assert_selector ".reaction-chip[data-reaction='👍'] .reaction-chip__count", text: "1", wait: 10
      assert_selector ".reaction-chip[data-reaction='👍'].reaction-chip--active"
    end

    assert_selector ".reaction-chip[data-reaction='👍'] .reaction-chip__count", text: "1", wait: 10
    assert_no_selector ".reaction-chip[data-reaction='👍'].reaction-chip--active"

    within_message(messages(:third)) do
      open_message_actions
      find(".message__quick-reaction[title='Thumbs up']").click
    end

    assert_selector ".reaction-chip[data-reaction='👍'] .reaction-chip__count", text: "2", wait: 10
    assert_selector ".reaction-chip[data-reaction='👍'].reaction-chip--active"

    using_session("David") do
      assert_selector ".reaction-chip[data-reaction='👍'] .reaction-chip__count", text: "2", wait: 10
      assert_selector ".reaction-chip[data-reaction='👍'].reaction-chip--active"
    end

    find(".reaction-chip[data-reaction='👍']").click
    assert_selector ".reaction-chip[data-reaction='👍'] .reaction-chip__count", text: "1", wait: 10
    assert_no_selector ".reaction-chip[data-reaction='👍'].reaction-chip--active"

    using_session("David") do
      assert_selector ".reaction-chip[data-reaction='👍'] .reaction-chip__count", text: "1", wait: 10
      assert_selector ".reaction-chip[data-reaction='👍'].reaction-chip--active"
    end
  end

  private
    def open_message_actions
      find("[data-message-edit-format], [data-reply-target='body']", match: :first).right_click
      assert_selector "[data-message-actions-target='menu']", visible: true, wait: 10
    end

    def perform_touch_gesture(node, move_by: nil, hold: 0.7)
      action = page.driver.browser.action
      touch = action.add_pointer_input(:touch, "message-touch")
      action.move_to(node.native, device: "message-touch")
      action.pointer_down(:left, device: "message-touch")
      action.move_by(*move_by, device: "message-touch") if move_by
      action.pause(device: touch, duration: hold)
      action.pointer_up(:left, device: "message-touch")
      action.perform
    end

    def save_screenshot(name)
      page.save_screenshot SCREENSHOT_DIR.join(name)
    end

    def assert_menu_within_viewport
      bounds = page.evaluate_script(<<~JS)
        (() => {
          const menu = document.querySelector(".message[data-message-actions-open] .message__actions-menu")
          if (!menu) return null
          const rect = menu.getBoundingClientRect()
          return {
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
            width: rect.width,
            height: rect.height,
            viewportWidth: window.innerWidth,
            viewportHeight: window.innerHeight
          }
        })()
      JS
      refute_nil bounds
      assert_operator bounds["left"], :>=, 0
      assert_operator bounds["top"], :>=, 0
      assert_operator bounds["right"], :<=, bounds["viewportWidth"]
      assert_operator bounds["bottom"], :<=, bounds["viewportHeight"]
    end
end
