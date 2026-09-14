require "application_system_test_case"

class WorkspaceMarkdownTest < ApplicationSystemTestCase
  MARKDOWN = <<~'MARKDOWN'.freeze
    ## Design review

    **Ready for review**, with _clear ownership_ and ~~old assumptions~~ removed.

    > Keep the conversation close to the work.

    - Check the channel layout
    - Review the code sample

    | Area | Status |
    | --- | --- |
    | Markdown | Ready |

    - [x] Source is preserved
    - [ ] Share feedback

    ```javascript
    const message = "<script>literal code</script>";
    console.log(message);
    ```

    [Project notes](https://example.com/notes)
  MARKDOWN

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
    page.driver.browser.execute_cdp "Emulation.setTouchEmulationEnabled", enabled: false
    page.current_window.resize_to(1400, 1400)
    emulate_theme "light"
  end

  test "Markdown messages reach other users and editing preserves the original source" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
    end

    fill_in_markdown "Write a message", with: MARKDOWN
    assert_field "Write a message", with: MARKDOWN
    click_on "Send Message"

    assert_selector ".message__body h2", text: "Design review"
    message = Message.find_by!(markdown_source: MARKDOWN)
    within_message(message) { assert_markdown_content }
    using_session("Kevin") do
      within_message(message) { assert_markdown_content }
    end

    within_message(message) do
      reveal_message_actions
      click_on "Edit", exact: true
      assert_field "Edit message", with: MARKDOWN
      fill_in_markdown "Edit message", with: MARKDOWN.sub("Design review", "Review complete")
      click_on "Save changes"
      assert_selector "h2", text: "Review complete"
    end

    using_session("Kevin") { assert_selector ".message__body h2", text: "Review complete" }
    join_room rooms(:designers)
    within_message(message) do
      reveal_message_actions
      click_on "Edit", exact: true
      assert_field "Edit message", with: MARKDOWN.sub("Design review", "Review complete")
    end
  end

  test "desktop keyboard composition keeps line breaks and sends once after composition ends" do
    editor = find_field("Write a message")
    editor.set "First line"
    editor.send_keys [ :shift, :enter ]
    editor.send_keys "Second line"
    assert_field "Write a message", with: "First line\nSecond line"

    page.execute_script <<~JS
      const editor = document.querySelector('textarea[name="message[markdown_source]"]');
      editor.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Enter', code: 'Enter', keyCode: 13, isComposing: true,
        bubbles: true, cancelable: true
      }));
    JS
    assert_field "Write a message", with: "First line\nSecond line"
    assert_not Message.exists?(markdown_source: "First line\nSecond line")

    editor.send_keys :enter
    assert_message_text "First line"
    assert_message_text "Second line"
    assert_equal 1, Message.where(markdown_source: "First line\nSecond line").count
    assert_field "Write a message", with: ""

    editor.send_keys :arrow_up
    assert_field "Edit message", with: "First line\nSecond line"
  end

  test "untrusted markup stays inert in the delivered message" do
    payload = <<~'MARKDOWN'
      Safety check

      <img src=x onerror="window.markdownPayloadExecuted=true">
      <script>window.markdownPayloadExecuted=true</script>
      [unsafe link](javascript:alert(1))

      ```html
      <img onerror="literal code">
      ```
    MARKDOWN

    fill_in_markdown "Write a message", with: payload
    click_on "Send Message"
    assert_message_text "Safety check"
    message = Message.find_by!(markdown_source: payload)
    within_message(message) do
      assert_selector "pre code", text: '<img onerror="literal code">'
      assert_no_selector "script, img[onerror], a[href^='javascript:']", visible: :all
    end
    assert_not page.evaluate_script("window.markdownPayloadExecuted === true")
  end

  test "Markdown replies and file attachments remain usable" do
    send_message "**A useful point** with `inline code`."
    assert_message_text "A useful point"
    message = Message.find_by!(markdown_source: "**A useful point** with `inline code`.")
    within_message(message) do
      reveal_message_actions
      click_on "Reply", exact: true
    end
    reply = find_field("Write a message").value
    assert_includes reply, ">"
    assert_includes reply, "A useful point"
    assert_not_includes reply, "Copy code"

    upload_path = Rails.root.join("tmp/markdown-workspace-attachment.txt")
    File.write(upload_path, "An attachment sent from the Markdown composer.\n")
    find("#composer input[type='file']", visible: :all).set(upload_path)
    assert_selector "#composer", text: "markdown-workspace-attachment"
    click_on "Send Message"
    assert_selector ".message[data-message-id] blockquote", text: "A useful point"
    assert_message_text "markdown-workspace-attachment.txt"
    assert Message.joins(:attachment_attachment).exists?
  ensure
    File.delete(upload_path) if upload_path && File.exist?(upload_path)
  end

  test "mention suggestions select a room member without sending the unfinished message" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
    end

    editor = find_field("Write a message")
    editor.set "@Kev"
    assert_selector "suggestion-option", text: "Kevin"
    editor.send_keys :enter
    assert_field "Write a message", with: "@[Kevin] "
    assert_not Message.exists?(markdown_source: "@Kev")
    assert_not Message.exists?(markdown_source: "@[Kevin] ")

    source = "@[Kevin] please review **the layout**."
    fill_in_markdown "Write a message", with: source
    click_on "Send Message"
    assert_selector ".message__body .mention", text: "Kevin"
    message = Message.find_by!(markdown_source: source)
    assert_equal [ users(:kevin) ], message.mentionees.to_a
    using_session("Kevin") do
      within_message(message) { assert_selector ".mention", text: "Kevin" }
      assert_selector "##{dom_id(message)}.message--mentioned"
      within_message(message) { assert_selector ".mention", text: "Kevin" }
    end
  end

  test "a rejected message can be recovered corrected and sent" do
    source = "A" * (Message::Markdown::SOURCE_LIMIT + 1)
    page.execute_script <<~JS, source
      const editor = document.querySelector('textarea[name="message[markdown_source]"]');
      editor.removeAttribute('maxlength');
      editor.value = arguments[0];
      editor.dispatchEvent(new Event('input', { bubbles: true }));
    JS
    click_on "Send Message"
    assert_selector ".message--failed"
    assert_not Message.exists?(markdown_source: source)
    click_on "Restore draft"
    assert_field "Write a message", with: source
    fill_in_markdown "Write a message", with: "**Recovered** after correcting the draft."
    click_on "Send Message"
    assert_selector ".message__body strong", text: "Recovered"
    assert_equal 1, Message.where(markdown_source: "**Recovered** after correcting the draft.").count
  end

  test "sending preserves the submitted source and a newer draft" do
    first = "**First message** stays exact."
    second = "A newer draft is still here."
    fill_in_markdown "Write a message", with: first

    page.execute_script <<~JS, second
      document.querySelector('#composer button[name="send"]').click();
      const editor = document.querySelector('#composer textarea[name="message[markdown_source]"]');
      editor.value = arguments[0];
      editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertFromPaste' }));
    JS

    assert_message_text "First message stays exact."
    assert_field "Write a message", with: second
    assert_equal 1, Message.where(markdown_source: first).count
    assert_not Message.exists?(markdown_source: second)
    click_on "Send Message"
    assert_message_text second
    assert_equal 1, Message.where(markdown_source: second).count
    assert_field "Write a message", with: ""
  end

  test "workspace follows the system theme and mobile navigation remains reachable" do
    send_message MARKDOWN
    assert_selector ".message__body h2", text: "Design review"
    assert_no_horizontal_overflow
    assert_compact_composer
    assert_profile_bar_within_navigation
    assert_selector "#channel-members [data-member-id='#{users(:jz).id}'][data-online='true']", wait: 5
    light_background = main_background
    settle_visual_transitions
    page.save_screenshot Rails.root.join("tmp/screenshots/workspace-light.png")

    emulate_theme "dark"
    assert page.evaluate_script("matchMedia('(prefers-color-scheme: dark)').matches")
    assert_not_equal light_background, main_background
    settle_visual_transitions
    assert_profile_bar_within_navigation
    page.save_screenshot Rails.root.join("tmp/screenshots/workspace-dark.png")

    page.current_window.resize_to(390, 844)
    assert_no_horizontal_overflow
    assert_compact_composer
    opener = find_button("Open workspace navigation")
    opener.click
    assert_button "Close workspace navigation"
    assert_selector "button[aria-label='Close workspace navigation']:focus"
    find_button("Close workspace navigation").send_keys [ :shift, :tab ]
    assert page.evaluate_script("document.querySelector('#sidebar').contains(document.activeElement)"), "focus should stay in the open navigation drawer"
    settle_visual_transitions
    assert_profile_bar_within_navigation
    page.save_screenshot Rails.root.join("tmp/screenshots/workspace-mobile-navigation.png")
    within("#sidebar") { click_link "HQ", exact: true }
    assert_selector ".room--current", text: "HQ"
    assert_no_button "Close workspace navigation", visible: true

    find_button("Open workspace navigation").click
    page.send_keys :escape
    assert_no_button "Close workspace navigation", visible: true
    assert_equal "Open workspace navigation", page.evaluate_script("document.activeElement.getAttribute('aria-label') || document.activeElement.textContent.trim()")
    assert_no_horizontal_overflow

    page.driver.browser.execute_cdp "Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1
    assert page.evaluate_script("matchMedia('(pointer: coarse)').matches")
    fill_in_markdown "Write a message", with: "Mobile draft"
    find_field("Write a message").send_keys :enter
    assert_field "Write a message", with: "Mobile draft\n"
    assert_not Message.exists?(markdown_source: "Mobile draft")
    click_on "Send Message"
    assert_message_text "Mobile draft"
    page.save_screenshot Rails.root.join("tmp/screenshots/workspace-mobile.png")
  end

  private
    def assert_compact_composer
      assert_field "Write a message", with: ""
      within("#composer") do
        assert_no_selector "[role='tablist'], [role='toolbar'], trix-editor"
        assert_no_text "Enter to send"
        assert_no_button "Rich text"
        assert_button "Send Message"
        assert_selector "input[type='file']", visible: :all
      end
      assert page.evaluate_script(<<~JS), "the empty composer should fit on a single compact row"
        (() => {
          const surface = document.querySelector('#composer .composer__surface').getBoundingClientRect();
          const field = document.querySelector('#composer textarea').getBoundingClientRect();
          const send = document.querySelector('#composer button[name="send"]').getBoundingClientRect();
          return surface.height <= 72 && send.top >= surface.top && send.bottom <= surface.bottom + 1 &&
            send.left >= field.right - 1;
        })()
      JS
    end

    def assert_profile_bar_within_navigation
      assert page.evaluate_script(<<~JS), "the profile bar must stay inside the navigation column"
        (() => {
          const navigation = document.querySelector('.sidebar__container').getBoundingClientRect();
          const profile = document.querySelector('.sidebar__tools').getBoundingClientRect();
          return Math.abs(profile.left - navigation.left) <= 1 &&
            Math.abs(profile.right - navigation.right) <= 1;
        })()
      JS
    end

    def assert_markdown_content
      assert_selector "h2", text: "Design review"
      assert_selector "strong", text: "Ready for review"
      assert_selector "em", text: "clear ownership"
      assert_selector "del", text: "old assumptions"
      assert_selector "blockquote", text: "Keep the conversation close to the work."
      assert_selector "ul li", text: "Check the channel layout"
      assert_selector "table td", text: "Markdown"
      assert_selector "input[type='checkbox'][disabled]", count: 2, visible: true
      assert_selector "pre code", text: 'const message = "<script>literal code</script>";'
      assert_link "Project notes", href: "https://example.com/notes"
    end

    def emulate_theme(theme)
      page.driver.browser.execute_cdp "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: theme } ]
    end

    def main_background
      page.evaluate_script("getComputedStyle(document.getElementById('main-content')).backgroundColor")
    end

    def settle_visual_transitions
      page.evaluate_async_script <<~JS
        const done = arguments[0];
        const finite = document.getAnimations().filter(animation =>
          Number.isFinite(animation.effect.getComputedTiming().endTime)
        );
        Promise.all(finite.map(animation => animation.finished.catch(() => {}))).then(done);
      JS
    end

    def assert_no_horizontal_overflow
      assert page.evaluate_script("document.documentElement.scrollWidth <= innerWidth + 1"), "the workspace overflows the viewport horizontally"
    end
end
