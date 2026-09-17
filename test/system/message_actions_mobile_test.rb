require "application_system_test_case"

class MessageActionsMobileTest < ApplicationSystemTestCase
  setup do
    @room = rooms(:designers)
    sign_in "jz@37signals.com"
    join_room @room
  end

  test "message action menu is a bottom sheet with touch-sized targets on phones" do
    page.current_window.resize_to(390, 844)
    within_message(messages(:third)) do
      open_message_actions
    end

    # Metadata reveals the edit/delete actions and re-runs placement, so
    # wait for it before measuring the final geometry.
    assert_selector ".message__edit-action", visible: true, wait: 10
    geometry = menu_geometry
    refute_nil geometry["menu"], "expected the message action menu to be open"

    menu = geometry["menu"]
    viewport = geometry["viewport"]

    assert_in_delta viewport["width"], menu["width"], 1, "expected the menu to span the viewport width"
    assert_in_delta viewport["height"], menu["bottom"], 1, "expected the menu to sit on the viewport bottom"
    assert_operator menu["height"], :<=, viewport["height"] * 0.7 + 1, "expected the menu to be at most 70vh tall"
    assert_operator menu["top"], :>=, 0
    assert_operator menu["left"], :>=, 0

    assert_not_empty geometry["reactions"], "expected quick reactions to be present"
    geometry["reactions"].each do |reaction|
      assert_operator reaction["width"], :>=, 44, "expected reaction targets at least 44px wide"
      assert_operator reaction["height"], :>=, 44, "expected reaction targets at least 44px tall"
    end
    assert_equal 1, geometry["reactionRows"], "expected the quick reactions to stay in a single row"

    assert_not_empty geometry["actions"], "expected menu actions to be present"
    geometry["actions"].each do |action|
      assert_operator action["height"], :>=, 44, "expected menu actions at least 44px tall"
    end

    find(".room-header__name").click
    assert_no_selector ".message[data-message-actions-open]"
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "message action menu stays a floating popover on desktop" do
    within_message(messages(:third)) do
      open_message_actions
    end

    geometry = menu_geometry
    refute_nil geometry["menu"], "expected the message action menu to be open"

    assert_operator geometry["menu"]["width"], :<, geometry["viewport"]["width"] - 1,
      "expected the desktop menu to be narrower than the viewport"

    page.send_keys :escape
    assert_no_selector ".message[data-message-actions-open]"
  end

  private
    def open_message_actions
      find("[data-message-edit-format], [data-reply-target='body']", match: :first).right_click
      assert_selector "[data-message-actions-target='menu']", visible: true, wait: 10
    end

    def menu_geometry
      page.evaluate_script(<<~JS)
        (() => {
          const menu = document.querySelector(".message[data-message-actions-open] .message__actions-menu")
          if (!menu) return { menu: null }
          const rect = menu.getBoundingClientRect()
          const visibleSizes = selector => Array.from(menu.querySelectorAll(selector))
            .filter(el => el.getClientRects().length > 0)
            .map(el => {
              const box = el.getBoundingClientRect()
              return { width: box.width, height: box.height, top: box.top }
            })
          const reactions = visibleSizes(".message__quick-reaction")
          return {
            menu: { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom, width: rect.width, height: rect.height },
            reactions,
            reactionRows: new Set(reactions.map(reaction => Math.round(reaction.top))).size,
            actions: visibleSizes(".message__menu-action"),
            viewport: { width: window.innerWidth, height: window.innerHeight }
          }
        })()
      JS
    end
end
