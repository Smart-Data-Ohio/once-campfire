require "application_system_test_case"

# Channel switches should feel like a native app: the current channel stays
# on screen until the next one renders, with no top progress bar flash and
# no full document reload.
class ChannelNavigationTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
  end

  test "switching channels hides the progress bar and lands without a reload" do
    join_room rooms(:hq)

    page.evaluate_script("window.__channelNavSentinel = 'alive'")
    delay_turbo_responses("^/rooms/[^/]+/?$", delay_ms: 1500)
    start_progress_bar_watch

    within "#sidebar" do
      click_link "Designers"
    end

    assert_title "Designers", wait: 10
    assert_selector ".room-header__name", text: "Designers", wait: 10
    assert_message_text "Third time's a charm.", wait: 10
    within "#sidebar" do
      assert_selector 'a[aria-current="page"]', text: "Designers", wait: 10
    end

    assert_fetch_was_delayed
    assert_no_progress_bar_shown
    assert_sentinel_alive
    assert_progress_bar_suppression_released
  end

  test "browser back returns to the previous channel without a reload" do
    join_room rooms(:hq)

    within "#sidebar" do
      click_link "Designers"
    end
    assert_title "Designers", wait: 10

    page.evaluate_script("window.__channelNavSentinel = 'alive'")
    go_back

    assert_title "HQ", wait: 10
    assert_selector ".room-header__name", text: "HQ", wait: 10
    within "#sidebar" do
      assert_selector 'a[aria-current="page"]', text: "HQ", wait: 10
    end
    assert_sentinel_alive
  end

  test "slow back and forward restores never flash the channel loader" do
    join_room rooms(:hq)
    within("#sidebar") { click_link "Designers" }
    assert_title "Designers", wait: 10

    page.evaluate_script("window.__channelNavSentinel = 'alive'")
    delay_turbo_responses("^/rooms/[0-9]+/?$", delay_ms: 1200)

    [ [ :go_back, "HQ" ], [ :go_forward, "Designers" ] ].each do |direction, room_name|
      # A restore normally uses a cached snapshot. Force the network path to
      # exercise a slow history visit as well as the cached-back test above.
      page.evaluate_async_script("const done = arguments[0]; import('@hotwired/turbo-rails').then(({Turbo}) => { Turbo.cache.clear(); done(); });")
      start_progress_bar_watch
      page.execute_script("window.__fetchDelayedCount = 0")
      page.public_send(direction)

      assert_title room_name, wait: 10
      assert_selector ".room-header__name", text: room_name, wait: 10
      assert_fetch_was_delayed
      assert_no_progress_bar_shown
      assert_sentinel_alive
      assert_progress_bar_suppression_released
    end
  end

  test "canceling a channel visit does not suppress the next page loader" do
    join_room rooms(:hq)
    page.execute_script <<~JS
      document.addEventListener("turbo:before-visit", event => event.preventDefault(), { once: true });
    JS
    within("#sidebar") { click_link "Designers" }
    assert_title "HQ"
    assert_progress_bar_suppression_released

    delay_turbo_responses("^/activity/?$", delay_ms: 1200)
    start_progress_bar_watch
    within("#sidebar") { click_link "Activity inbox" }
    assert_title "Activity inbox", wait: 10
    assert_fetch_was_delayed
    assert_operator progress_bar_seen, :>=, 1
  end

  test "shared message links also navigate without a channel loader" do
    join_room rooms(:hq)
    page.execute_script <<~JS, room_at_message_path(rooms(:designers), messages(:third))
      document.querySelector('#sidebar a[href="#{room_path(rooms(:designers))}"]').href = arguments[0];
    JS
    delay_turbo_responses("^/rooms/[0-9]+/@[0-9]+/?$", delay_ms: 1200)
    start_progress_bar_watch
    within("#sidebar") { click_link "Designers" }
    assert_title "Designers", wait: 10
    assert_message_text "Third time's a charm.", wait: 10
    assert_fetch_was_delayed
    assert_no_progress_bar_shown
    assert_progress_bar_suppression_released
  end

  test "channel switch from the mobile drawer closes the drawer without a reload" do
    join_room rooms(:hq)

    page.current_window.resize_to(390, 844)
    page.evaluate_script("window.__channelNavSentinel = 'alive'")

    click_button "Open workspace navigation"
    assert_selector "#sidebar.open"

    within "#sidebar" do
      click_link "Designers"
    end

    assert_title "Designers", wait: 10
    assert_no_selector "#sidebar.open"
    assert_sentinel_alive
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "non-room visits still show the progress bar" do
    join_room rooms(:hq)

    delay_turbo_responses("^/activity/?$", delay_ms: 1200)
    start_progress_bar_watch

    within "#sidebar" do
      click_link "Activity inbox"
    end

    assert_title "Activity inbox", wait: 10
    assert_selector "#activity-inbox-title", wait: 10

    assert_fetch_was_delayed
    assert_operator progress_bar_seen, :>=, 1, "expected the progress bar to appear for a slow non-room visit"
  end

  private
    # Delays Turbo responses whose path matches the pattern, so the
    # destination arrives well after Turbo's 500ms progress bar delay.
    # Turbo captures window.fetch at load, so this uses Turbo's own
    # turbo:before-fetch-request interception point instead: swapping in
    # event.detail.fetchRequest.response keeps the progress bar timer
    # running while the destination is "slow". Counts delayed requests to
    # guard the test premise.
    def delay_turbo_responses(path_pattern, delay_ms:)
      page.evaluate_script(<<~JS)
        (() => {
          if (window.__turboResponseDelayerInstalled) return "already-installed"
          window.__turboResponseDelayerInstalled = true
          window.__fetchDelayedCount = 0
          const pattern = new RegExp(#{path_pattern.inspect})
          const delayMs = #{delay_ms}
          document.addEventListener("turbo:before-fetch-request", (event) => {
            let pathname = null
            try {
              pathname = new URL(event.detail.url, window.location.origin).pathname
            } catch {
              return
            }
            if (!pattern.test(pathname)) return
            window.__fetchDelayedCount += 1
            const url = event.detail.url
            const fetchOptions = event.detail.fetchOptions
            event.detail.fetchRequest = {
              response: new Promise((resolve, reject) => {
                setTimeout(() => window.fetch(url, fetchOptions).then(resolve, reject), delayMs)
              })
            }
          })
          return "installed"
        })()
      JS
    end

    # Counts insertions of a *visible* .turbo-progress-bar: the suppression
    # under test hides the bar with CSS, so merely present nodes prove nothing.
    def start_progress_bar_watch
      page.evaluate_script(<<~JS)
        (() => {
          window.__progressBarSeen = 0
          if (window.__progressBarObserver) window.__progressBarObserver.disconnect()
          const observer = new MutationObserver((mutations) => {
            for (const mutation of mutations) {
              for (const node of mutation.addedNodes) {
                if (node.nodeType !== 1) continue
                const bars = node.matches(".turbo-progress-bar")
                  ? [ node ]
                  : Array.from(node.querySelectorAll(".turbo-progress-bar"))
                for (const bar of bars) {
                  if (getComputedStyle(bar).display !== "none") window.__progressBarSeen += 1
                }
              }
            }
          })
          observer.observe(document.documentElement, { childList: true, subtree: true })
          window.__progressBarObserver = observer
        })()
      JS
    end

    def assert_fetch_was_delayed
      assert_operator fetch_delayed_count, :>=, 1, "expected the destination response to be delayed past the progress bar threshold"
    end

    def assert_no_progress_bar_shown
      assert_equal 0, progress_bar_seen, "expected no visible progress bar during the channel switch"
    end

    def assert_sentinel_alive
      assert_equal "alive", page.evaluate_script("window.__channelNavSentinel"),
        "expected no full document reload during navigation"
    end

    def assert_progress_bar_suppression_released
      # Rendering the destination title precedes Turbo's terminal load event.
      assert_no_selector "html[data-channel-navigation]", visible: :all, wait: 10
    end

    def fetch_delayed_count
      page.evaluate_script("window.__fetchDelayedCount")
    end

    def progress_bar_seen
      page.evaluate_script("window.__progressBarSeen")
    end
end
