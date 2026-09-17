require "application_system_test_case"

class AgentsDirectoryTest < ApplicationSystemTestCase
  setup do
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    page.current_window.resize_to(1440, 1000)
    sign_in "kevin@37signals.com"
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
    page.current_window.resize_to(1400, 1400)
  end

  test "member opens the agent directory and an agent profile" do
    agents(:bender_agent).update!(
      provider: "OpenAI", runtime: "Codex CLI 0.9", description: "Does things",
      status: "working", status_note: "on it"
    )
    join_room rooms(:designers)

    click_on "Agents"

    assert_selector "h1", text: "Agents"
    assert_selector ".agent-directory-row", text: "Bender Bot"
    assert_selector ".agent-directory-row", text: "Workspace agent, managed by David"
    assert_selector ".agent-directory-row", text: "Working"

    find(".agent-directory-row .txt-large a", text: "Bender Bot").click

    assert_selector "h1", text: "Bender Bot"
    assert_text "Workspace agent, managed by David"
    assert_text "OpenAI"
    assert_text "Does things"
    assert_text "Working"
  end
end
