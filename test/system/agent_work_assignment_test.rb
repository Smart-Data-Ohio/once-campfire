require "application_system_test_case"

class AgentWorkAssignmentTest < ApplicationSystemTestCase
  setup do
    @room = rooms(:designers)
    @bot = User.create_bot!(name: "Work Agent")
    @agent = @bot.create_agent!(kind: :workspace, owner: users(:david))
    @agent.update!(provider: "TestLab", description: "Does assigned work")
    @room.memberships.grant_to(@bot)
    %w[ read_messages post_messages manage_threads ].each do |capability|
      AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: capability)
    end
    _, @secret = AgentCredential.create_with_secret!(agent: @agent, name: "system", created_by: users(:david))

    sign_in "jz@37signals.com"
    join_room @room
  end

  test "assigns an agent from the update dialog and renders its API status change after refresh" do
    thread_name = "Agent owned thread"
    create_thread_from_panel(thread_name, "Work the agent will pick up.")
    thread = ChannelThread.find_by!(name: thread_name)

    find("#thread-panel [data-thread-panel-target='manage'] summary").click
    click_button "Track as work"
    assert_selector "#thread-panel [data-thread-panel-target='work']", visible: true, wait: 10

    find("#thread-panel [data-thread-panel-target='workManage'] summary").click
    assert_selector "#thread-panel [data-thread-panel-target='workOwner'] optgroup[label='Agents'] option", text: "Work Agent", wait: 10
    find("#thread-panel [data-thread-panel-target='workOwner'] option", text: "Work Agent").select_option
    wait_for_condition { thread.reload.work_owner_id == @bot.id }
    assert_selector "#thread-panel [data-thread-panel-target='workOwnerLabel'] .agent-badge", text: "agent", wait: 10

    result = patch_work_as_agent(thread, work_status: "in_progress", note: "Agent started the work")
    assert_equal 200, result["status"]
    assert_equal "in_progress", thread.reload.work_status

    visit room_url(@room, thread: thread.id)
    assert_selector "#thread-panel [data-thread-panel-target='conversation']", visible: true, wait: 10
    assert_selector "#thread-panel [data-thread-panel-target='conversationTitle']", text: thread_name, wait: 10
    assert_selector "#thread-panel [data-thread-panel-target='workStatusLabel']", text: "In progress", wait: 10
    assert_selector "#thread-panel [data-thread-panel-target='workOwnerLabel'] .agent-badge", text: "agent", wait: 10

    find("#thread-panel [data-thread-panel-target='workHistory'] summary").click
    assert_selector "#thread-panel [data-thread-panel-target='workHistoryList']", text: /Agent started the work/, wait: 10
    assert_selector "#thread-panel [data-thread-panel-target='workHistoryList']", text: /Planned → In progress/, wait: 10
  end

  private
    def open_threads
      find("[data-thread-panel-target='browserToggle']").click unless page.has_css?("body.thread-panel-open", wait: 0)
      assert_selector "#thread-panel[aria-hidden='false']", visible: true, wait: 10
    end

    def create_thread_from_panel(name, first_message)
      open_threads
      click_button "New thread"
      assert_selector "#thread-panel [data-thread-panel-target='create']", visible: true, wait: 10
      fill_in "Thread name", with: name
      fill_in "First message", with: first_message
      find("#thread-panel [data-thread-panel-target='createSubmit']").click
      assert_selector "#thread-panel [data-thread-panel-target='conversation']", visible: true, wait: 10
      assert_selector "#thread-panel [data-thread-panel-target='conversationTitle']", text: name, wait: 10
    end

    # Calls the Bearer-only agent API from the page without the session
    # cookie, so authentication resolves to the agent token.
    def patch_work_as_agent(thread, work_status:, note:)
      page.evaluate_async_script(<<~JS, thread.id, @secret, work_status, note)
        const [threadId, secret, status, note, done] = arguments;
        fetch(`/agents/work/${threadId}`, {
          method: "PATCH",
          credentials: "omit",
          headers: { "Authorization": `Bearer ${secret}`, "Content-Type": "application/json" },
          body: JSON.stringify({ work_status: status, note: note })
        }).then(async (response) => done({ status: response.status, body: await response.json() }))
          .catch((error) => done({ status: 0, error: String(error) }));
      JS
    end

    def wait_for_condition(timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
      assert yield
    end
end
