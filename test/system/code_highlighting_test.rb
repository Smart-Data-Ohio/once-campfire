require "application_system_test_case"

class CodeHighlightingTest < ApplicationSystemTestCase
  SAMPLES = {
    "ts" => 'interface Person { name: string }; const person: Person = { name: "Sam" };',
    "tsx" => "const Greeting = () => <strong>Hello</strong>;",
    "csharp" => 'public class Greeting { public string Name => "Sam"; }',
    "c#" => 'public class Greeting { public string Name => "Sam"; }',
    "c" => "int main(void) { return 0; }",
    "c++" => "template<typename T> class Greeting { public: T value; };",
    "yml" => "enabled: true",
    "dockerfile" => "FROM ruby:3.4",
    "powershell" => 'Write-Host "Hello"',
    "python" => 'def greet(name): return "Hello " + name',
    "sql" => "SELECT name FROM users WHERE active = true;",
    "html" => '<img src=x onerror="window.codeExecuted=true">'
  }.freeze

  setup do
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  teardown do
    page.driver.browser.execute_cdp "Emulation.setEmulatedMedia", features: []
    page.current_window.resize_to(1400, 1400)
  end

  test "language fences highlight common code without changing its text" do
    source = SAMPLES.map { |language, code| "```#{language}\n#{code}\n```" }.join("\n\n")
    send_message source
    assert_selector ".message__body pre code", count: SAMPLES.size

    SAMPLES.each do |language, source_code|
      code = find("pre code[class~='language-#{language}'][data-highlighted='yes']")
      assert_selector "pre code[class~='language-#{language}'] .code-token"
      assert_equal source_code + "\n", code.evaluate_script("this.textContent")
    end
    assert_no_selector ".message__body pre img, .message__body pre script", visible: :all
    assert_not page.evaluate_script("window.codeExecuted === true")
    assert_equal "csharp", find("pre code[class~='language-c#']")["data-code-language"]
    assert_equal "cpp", find("pre code[class~='language-c++']")["data-code-language"]

    # Exercise the actual copy button while keeping the test independent of
    # browser clipboard permission prompts.
    page.execute_script <<~JS
      navigator.clipboard.writeText = async text => { window.copiedCode = text; };
    JS
    within(find("pre code.language-ts").find(:xpath, "..")) do
      click_button "Copy code"
      assert_button "Code copied"
    end
    assert_equal SAMPLES.fetch("ts") + "\n", page.evaluate_script("window.copiedCode")
  end

  test "unlabelled code is detected while text unknown languages and inline code stay literal" do
    source = <<~'MARKDOWN'
      `const inline = true;`

      ```
      def greet(name):
          return "Hello " + name
      ```

      ```text
      const plain = "@[JZ] :smile:";
      ```

      ```unknown-language
      <script>window.codeExecuted = true</script>
      ```
    MARKDOWN
    send_message source
    assert_selector "pre.code-highlighted code .code-token"
    assert_selector "pre code.language-text[data-highlighted='yes']", text: 'const plain = "@[JZ] :smile:";'
    assert_no_selector "code.language-text span, code.language-unknown-language span, p code span"
    assert_selector "code.language-unknown-language", text: "<script>window.codeExecuted = true</script>"
    assert_no_selector ".message__body pre script", visible: :all
    assert_not page.evaluate_script("window.codeExecuted === true")
    assert_selector ".markdown-code-copy", count: 3
  end

  test "search results highlight code on initial load and after returning to the channel" do
    source = "HighlightSearchExample\n\n```javascript\nconst value = true;\n```"
    message = rooms(:designers).messages.create!(creator: users(:jz), markdown_source: source, client_message_id: SecureRandom.uuid)

    visit searches_url(q: "HighlightSearchExample")
    within_message(message) do
      assert_selector "pre code.language-javascript[data-highlighted='yes'] .code-token", text: "const"
      assert_selector ".markdown-code-copy", count: 1
    end

    click_link "Exit search"
    assert_current_path room_path(rooms(:designers))
    within_message(message) do
      assert_selector "pre code.language-javascript[data-highlighted='yes'] .code-token", text: "const"
      assert_selector ".markdown-code-copy", count: 1
    end

    page.go_back
    assert_current_path searches_path(q: "HighlightSearchExample")
    page.execute_script "navigator.clipboard.writeText = async text => { window.copiedCode = text; };"
    within_message(message) do
      click_button "Copy code"
      assert_button "Code copied"
    end
    assert_equal "const value = true;\n", page.evaluate_script("window.copiedCode")
  end

  test "code and copying remain available when the highlighter cannot load" do
    page.execute_script "window.Worker = class { constructor() { window.highlighterWorkerFailed = true; throw new Error('Worker unavailable'); } };"
    source = "```ts\nconst value: string = \"hello\";\n```"
    send_message source
    assert_selector "pre code.language-ts", text: 'const value: string = "hello";'
    page.execute_script "navigator.clipboard.writeText = async text => { window.copiedCode = text; };"
    click_button "Copy code"
    assert_button "Code copied"
    assert_equal "const value: string = \"hello\";\n", page.evaluate_script("window.copiedCode")
    assert page.evaluate_script("window.highlighterWorkerFailed === true")
    assert_no_selector "pre code[data-highlighted], pre .code-token"
    assert_field "Write a message", with: ""
  end

  test "editing a code block replaces its language colors and copied source" do
    source = "```ts\nconst value: string = \"hello\";\n```"
    send_message source
    assert_selector "pre code.language-ts[data-highlighted='yes'] .code-token", text: "const"
    message = Message.find_by!(markdown_source: source)
    within_message(message) do
      reveal_message_actions
      click_on "Edit message", exact: true
    end

    replacement = "```python\ndef greet(name):\n    return \"Hello \" + name\n```"
    fill_in_markdown "Write a message", with: replacement
    click_on "Send Message"
    within_message(message) do
      assert_selector "pre code.language-python[data-highlighted='yes'] .code-token", text: "def"
      assert_no_selector "code.language-ts"
      assert_selector ".markdown-code-copy", count: 1
      page.execute_script "navigator.clipboard.writeText = async text => { window.copiedCode = text; };"
      click_button "Copy code"
      assert_button "Code copied"
    end
    assert_equal "def greet(name):\n    return \"Hello \" + name\n", page.evaluate_script("window.copiedCode")
    assert_equal replacement, message.reload.markdown_source.gsub("\r\n", "\n")
  end

  test "thread code stays readable in both themes and scrolls within a narrow screen" do
    thread = ChannelThread.create!(room: rooms(:designers), creator: users(:jz), name: "Code review")
    ThreadMembership.join!(thread, users(:jz))
    source_code = 'const greeting: string = "' + "Hello " * 40 + '";'
    message = thread.messages.create!(room: rooms(:designers), creator: users(:jz), markdown_source: "```ts\n#{source_code}\n```", client_message_id: SecureRandom.uuid)

    visit room_url(rooms(:designers), thread: thread.id, message_id: message.id)
    within_message(message) do
      assert_selector "pre code.language-ts[data-highlighted='yes'] .code-token", text: "const"
    end

    colors = %w[ light dark ].map do |theme|
      page.driver.browser.execute_cdp "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: theme } ]
      code = find("#thread-panel pre code.language-ts")
      keyword = code.find(".code-token", text: "const")
      assert_not_equal code.evaluate_script("getComputedStyle(this).color"), keyword.evaluate_script("getComputedStyle(this).color")
      page.save_screenshot Rails.root.join("tmp/screenshots/code-highlighting-#{theme}.png")
      keyword.evaluate_script("getComputedStyle(this).color")
    end
    assert_equal [ "rgb(0, 0, 255)", "rgb(86, 156, 214)" ], colors

    page.current_window.resize_to(390, 844)
    assert page.evaluate_script("document.documentElement.scrollWidth <= innerWidth + 1")
    assert find("#thread-panel pre").evaluate_script("this.scrollWidth > this.clientWidth")
    assert_selector "#thread-panel .markdown-code-copy", count: 1
    page.save_screenshot Rails.root.join("tmp/screenshots/code-highlighting-mobile.png")
  end
end
