require "application_system_test_case"

class ChannelMembersTest < ApplicationSystemTestCase
  self.use_transactional_tests = false

  setup do
    WorkspacePresenceLease.delete_all
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    page.current_window.resize_to(1440, 1000)
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
    assert_selector "#channel-members"
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
    page.driver.browser.execute_cdp "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ]
    page.current_window.resize_to(1400, 1400)
  end

  test "members are online across channels and go offline after signing out" do
    assert_member users(:jz), online: true
    assert_member users(:kevin), online: false
    assert_no_selector "#channel-members [data-member-id='#{users(:bender).id}']", visible: :all

    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:hq)
    end
    memberships(:kevin_designers).update!(unread_at: Time.current)

    assert_member users(:kevin), online: true
    assert memberships(:kevin_designers).reload.unread?, "workspace presence must not mark another channel as read"
    assert_composer_alignment
    page.driver.browser.execute_cdp "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "dark" } ]
    settle_visual_transitions
    page.save_screenshot Rails.root.join("tmp/screenshots/members-online.png")

    using_session("Kevin") do
      visit user_profile_url
      click_on "Log out"
      assert_field "email_address"
    end

    assert_member users(:kevin), online: false
    assert_member users(:jz), online: true
  end

  test "closing one tab keeps a member online until their last tab closes" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:hq)
      extra_tab = open_new_window
      within_window(extra_tab) { join_room rooms(:hq) }
      wait_for_lease_count users(:kevin), 2
      extra_tab.close
      wait_for_lease_count users(:kevin), 1
    end

    assert_member users(:kevin), online: true

    using_session("Kevin") { visit "about:blank" }
    wait_for_lease_count users(:kevin), 0
    assert_member users(:kevin), online: false
    assert users(:kevin).sessions.exists?, "closing the app should not need to end the login session"
  end

  test "the member panel follows channel access and remains usable on a phone" do
    private_room = Rooms::Closed.create_for({ name: "Planning", creator: users(:jz) }, users: [ users(:jz), users(:bender) ])
    join_room private_room
    assert_member users(:bender), online: false
    assert_no_selector "#channel-members [data-member-id='#{users(:kevin).id}']", visible: :all
    assert_no_selector "#channel-members [data-member-id='#{users(:david).id}']", visible: :all

    click_button "Hide members"
    assert_no_selector "#channel-members", visible: true
    click_button "Show members"
    assert_selector "#channel-members"

    page.current_window.resize_to(390, 844)
    assert_no_selector "#channel-members", visible: true
    assert_no_horizontal_overflow
    assert_composer_alignment
    click_button "Show members"
    assert_button "Close members"
    assert_member users(:bender), online: false
    assert_selector "button[aria-label='Close members']:focus"
    page.send_keys [ :shift, :tab ]
    assert page.evaluate_script("document.querySelector('#channel-members').contains(document.activeElement)"), "focus should stay in the open member drawer"
    page.send_keys :escape
    assert_no_selector "#channel-members", visible: true
    assert_equal "Show members", page.evaluate_script("document.activeElement.getAttribute('aria-label')")

    click_button "Show members"
    settle_visual_transitions
    page.save_screenshot Rails.root.join("tmp/screenshots/members-mobile.png")
    click_button "Close members"
    send_message "Still easy to chat on a phone."
    assert_message_text "Still easy to chat on a phone."
    assert_composer_alignment

    page.current_window.resize_to(320, 740)
    assert_no_horizontal_overflow
    assert_button "Show members"
    assert_composer_alignment
  ensure
    private_room&.destroy!
  end

  private
    def assert_member(user, online:)
      assert_selector "#channel-members [data-member-id='#{user.id}'][data-online='#{online}']", text: user.name, visible: :all, wait: 20
    end

    def wait_for_lease_count(user, count)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      until WorkspacePresenceLease.unexpired.where(user: user).count == count
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          leases = WorkspacePresenceLease.where(user: user).order(:id).pluck(:id, :connection_id, :session_id, :expires_at)
          flunk "expected #{count} live workspace connections for #{user.name}; leases: #{leases.inspect}"
        end
        sleep 0.1
      end
      assert true
    end

    def assert_composer_alignment
      assert_field "Write a message", with: ""
      offsets = page.evaluate_script <<~JS
        (() => {
          const field = document.querySelector('#composer textarea');
          const bounds = field.getBoundingClientRect();
          const style = getComputedStyle(field);
          const textCenter = bounds.top + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop) + parseFloat(style.lineHeight) / 2;
          return ['.composer__attachment-btn', '.composer__send'].map(selector => {
            const button = document.querySelector(selector).getBoundingClientRect();
            return Math.abs(button.top + button.height / 2 - textCenter);
          });
        })()
      JS
      assert offsets.all? { |offset| offset <= 1 }, "composer controls are offset from the text line by #{offsets.inspect} pixels"
    end

    def assert_no_horizontal_overflow
      assert page.evaluate_script("document.documentElement.scrollWidth <= innerWidth + 1"), "the workspace overflows the viewport horizontally"
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
end
