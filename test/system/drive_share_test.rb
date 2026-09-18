require "application_system_test_case"

# Enhanced Drive share picker flows with a fully mocked Google: the
# Identity Services token client, the Picker, and Drive REST are all
# doubles installed on window, so these tests never contact live Google
# and never change real Drive permissions.
class DriveShareTest < ApplicationSystemTestCase
  include GoogleCalendarTestHelper

  FILE_ID = "1AbcDefGhIjKlMnOpQrSt"

  DRIVE_FILE_SCOPE = "https://www.googleapis.com/auth/drive.file"

  # Installs window.google (GIS + Picker) and wraps window.fetch so Drive
  # REST is answered from the scenario. Same-origin recipients calls pass
  # through to the app but are logged. Receives the scenario JSON as its
  # first script argument.
  MOCK_JS = <<~JS
    const scenario = JSON.parse(arguments[0]);
    const mock = window.__driveShareMock = {
      scenario,
      initTokenCalls: [],
      requestTokenCalls: [],
      pickerBuilds: [],
      pickerVisible: [],
      driveCalls: [],
      createOrder: [],
      recipientsCalls: [],
      listFailedOnce: false,
      createFailedOnce: false
    };

    window.google = window.google || {};
    window.google.accounts = { oauth2: {
      initTokenClient(config) {
        mock.lastTokenConfig = config;
        mock.initTokenCalls.push({
          scope: config.scope,
          include_granted_scopes: config.include_granted_scopes,
          client_id: config.client_id
        });
        return {
          requestAccessToken(override) {
            mock.requestTokenCalls.push(override || {});
            const response = JSON.parse(JSON.stringify(mock.scenario.token));
            setTimeout(() => config.callback(response), 0);
          }
        };
      },
      hasGrantedAllScopes: (response) => !response.error && !!response.access_token
    }};

    class MockDocsView {
      constructor(viewId) { this.viewId = viewId; }
      setIncludeFolders(value) { return this; }
      setSelectFolderEnabled(value) { return this; }
      setMode(value) { return this; }
    }
    class MockBuilder {
      constructor() { this.args = {}; }
      addView(view) { return this; }
      setOAuthToken(token) { this.args.oauthToken = token; return this; }
      setDeveloperKey(key) { this.args.developerKey = key; return this; }
      setAppId(id) { this.args.appId = id; return this; }
      setCallback(callback) { this.args.callback = callback; return this; }
      setOrigin(origin) { this.args.origin = origin; return this; }
      setTitle(title) { return this; }
      build() {
        mock.pickerBuilds.push({ ...this.args, callback: !!this.args.callback });
        const callback = this.args.callback;
        mock.lastPickerCallback = callback;
        return { setVisible: (visible) => {
          mock.pickerVisible.push(visible);
          if (!visible) return;
          setTimeout(() => {
            const pick = mock.scenario.picker;
            if (pick === "manual") return;
            if (pick === "cancel") callback({ action: "cancel" });
            else callback({ action: "picked", docs: [pick] });
          }, 0);
        }};
      }
    }
    window.google.picker = {
      DocsView: MockDocsView,
      ViewId: { DOCS: "docs" },
      DocsViewMode: { LIST: "list" },
      PickerBuilder: MockBuilder,
      Response: { ACTION: "action", DOCUMENTS: "docs" },
      Action: { PICKED: "picked", CANCEL: "cancel" },
      Document: { ID: "id", NAME: "name", MIME_TYPE: "mimeType" }
    };

    window.__driveShareRespond = (url, options) => {
      const live = window.__driveShareMock;
      const expectedAuth = `Bearer ${live.scenario.token.access_token}`;
      if ((options.headers || {}).Authorization !== expectedAuth) {
        return { status: 401, body: { error: { code: 401 } } };
      }
      const path = new URL(url).pathname;
      const method = options.method || "GET";
      if (method === "POST" && path.endsWith("/permissions")) {
        const body = JSON.parse(options.body);
        live.createOrder.push(body.emailAddress);
        if (live.scenario.create401OnAttempt && live.createOrder.length === live.scenario.create401OnAttempt && !live.createFailedOnce) {
          live.createFailedOnce = true;
          return { status: 401, body: { error: { code: 401 } } };
        }
        if (live.scenario.fillStripOnCreate) {
          const strip = document.querySelector(".composer__drive-attachments");
          for (let i = 0; i < 10; i++) {
            const chip = document.createElement("span");
            chip.className = "drive-attachment-chip";
            const input = document.createElement("input");
            input.type = "hidden";
            input.name = "message[drive_file_ids][]";
            input.value = `midflight${i}1`;
            chip.append(input);
            strip.append(chip);
          }
          live.scenario.fillStripOnCreate = false;
        }
        const behavior = (live.scenario.creates || {})[body.emailAddress] || "ok";
        if (behavior === "ok") return { status: 200, body: { id: `perm-${body.emailAddress}`, role: "reader" } };
        return { status: behavior.status || 403, body: { error: { errors: [{ reason: behavior.reason || "forbidden" }], code: behavior.status || 403 } } };
      }
      if (method === "GET" && path.endsWith("/permissions")) {
        if (live.scenario.failFirstListWith401 && !live.listFailedOnce) {
          live.listFailedOnce = true;
          return { status: 401, body: { error: { code: 401 } } };
        }
        const token = new URL(url).searchParams.get("pageToken");
        const index = token ? parseInt(token.replace("page", ""), 10) : 0;
        const pages = live.scenario.permissionPages || [[]];
        const body = { permissions: pages[index] || [] };
        if (index + 1 < pages.length) body.nextPageToken = `page${index + 1}`;
        return { status: 200, body };
      }
      if (method === "GET" && path.startsWith("/drive/v3/files/")) {
        if (live.scenario.file && live.scenario.file.error) {
          return { status: live.scenario.file.error.status || 403, body: { error: { code: live.scenario.file.error.status || 403 } } };
        }
        return { status: 200, body: live.scenario.file };
      }
      return { status: 404, body: {} };
    };

    if (!window.__driveShareFetchWrapped) {
      window.__driveShareFetchWrapped = true;
      const realFetch = window.fetch.bind(window);
      window.fetch = (input, options = {}) => {
        const live = window.__driveShareMock;
        const url = String(input && input.url ? input.url : input);
        if (url.startsWith("https://www.googleapis.com/drive/v3/")) {
          live.driveCalls.push({
            url, method: options.method || "GET",
            auth: (options.headers || {}).Authorization || null,
            body: typeof options.body === "string" ? options.body : null
          });
          const { status, body } = window.__driveShareRespond(url, options);
          return Promise.resolve(new Response(JSON.stringify(body), { status }));
        }
        if (url.includes("/drive_recipients")) {
          live.recipientsCalls.push({ url, method: options.method || "GET", body: options.body || null });
        }
        return realFetch(input, options);
      };
    }
  JS

  # GIS-only mocks plus a gapi.load stub that installs the Picker mock
  # asynchronously, exercising the lazy-load path without any network.
  LAZY_MOCK_JS = <<~JS
    const scenario = JSON.parse(arguments[0]);
    const mock = window.__driveShareMock = {
      scenario,
      initTokenCalls: [],
      requestTokenCalls: [],
      pickerBuilds: [],
      pickerVisible: [],
      driveCalls: [],
      createOrder: [],
      recipientsCalls: [],
      listFailedOnce: false,
      seedPicker() {
        class MockDocsView {
          setIncludeFolders(value) { return this; }
          setSelectFolderEnabled(value) { return this; }
          setMode(value) { return this; }
        }
        class MockBuilder {
          constructor() { this.args = {}; }
          addView(view) { return this; }
          setOAuthToken(token) { this.args.oauthToken = token; return this; }
          setDeveloperKey(key) { this.args.developerKey = key; return this; }
          setAppId(id) { this.args.appId = id; return this; }
          setCallback(callback) { this.args.callback = callback; return this; }
          setOrigin(origin) { this.args.origin = origin; return this; }
          setTitle(title) { return this; }
          build() {
            mock.pickerBuilds.push({ ...this.args, callback: !!this.args.callback });
            const callback = this.args.callback;
            return { setVisible: (visible) => {
              mock.pickerVisible.push(visible);
              if (!visible) return;
              setTimeout(() => callback({ action: "picked", docs: [mock.scenario.picker] }), 0);
            }};
          }
        }
        window.google.picker = {
          DocsView: MockDocsView,
          ViewId: { DOCS: "docs" },
          DocsViewMode: { LIST: "list" },
          PickerBuilder: MockBuilder,
          Response: { ACTION: "action", DOCUMENTS: "docs" },
          Action: { PICKED: "picked", CANCEL: "cancel" },
          Document: { ID: "id", NAME: "name", MIME_TYPE: "mimeType" }
        };
      }
    };

    window.google = window.google || {};
    window.google.accounts = { oauth2: {
      initTokenClient(config) {
        mock.initTokenCalls.push({ scope: config.scope, include_granted_scopes: config.include_granted_scopes });
        return { requestAccessToken: (override) => {
          mock.requestTokenCalls.push(override || {});
          const response = JSON.parse(JSON.stringify(mock.scenario.token));
          setTimeout(() => config.callback(response), 0);
        }};
      },
      hasGrantedAllScopes: (response) => !response.error && !!response.access_token
    }};
    window.gapi = { load: (_modules, opts) => setTimeout(() => {
      if (mock.scenario.failPickerLoad) opts.onerror(new Error("load failed"));
      else { mock.seedPicker(); opts.callback(); }
    }, 0) };

    window.__driveShareRespond = (_url, _options) => ({ status: 200, body: window.__driveShareMock.scenario.file });

    if (!window.__driveShareFetchWrapped) {
      window.__driveShareFetchWrapped = true;
      const realFetch = window.fetch.bind(window);
      window.fetch = (input, options = {}) => {
        const live = window.__driveShareMock;
        const url = String(input && input.url ? input.url : input);
        if (url.startsWith("https://www.googleapis.com/drive/v3/")) {
          live.driveCalls.push({ url, method: options.method || "GET", auth: (options.headers || {}).Authorization || null, body: null });
          const { status, body } = window.__driveShareRespond(url, options);
          return Promise.resolve(new Response(JSON.stringify(body), { status }));
        }
        if (url.includes("/drive_recipients")) {
          live.recipientsCalls.push({ url, method: options.method || "GET", body: options.body || null });
        }
        return realFetch(input, options);
      };
    }
  JS

  setup do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)

    @picker_env_before_test = [ ENV["GOOGLE_PICKER_API_KEY"], ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] ]
    ENV["GOOGLE_PICKER_API_KEY"] = "test-picker-key"
    ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = "123456789012"

    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  teardown do
    ENV["GOOGLE_PICKER_API_KEY"], ENV["GOOGLE_CLOUD_PROJECT_NUMBER"] = @picker_env_before_test
    WebMock.reset!
    WebMock.disable!
  end

  def after_teardown
    super
  ensure
    WebMock.reset!
    WebMock.disable!
  end

  test "review dialog offers attach-only and an explicit grant with names and emails" do
    inject_drive_share_mocks(drive_scenario)

    find("button.composer__drive-btn").click

    within(".drive-share-dialog") do
      assert_selector ".drive-share-dialog__file", text: "Q3 Planning"
      assert_text "Access grants happen immediately"
      assert_text "Future members are not added automatically"
      assert_text "Only view access is granted"
      assert_selector ".drive-share-dialog__recipient", count: 3
      assert_selector ".drive-share-dialog__recipient", text: "David"
      assert_selector ".drive-share-dialog__recipient", text: "david@37signals.com"
      assert_selector ".drive-share-dialog__recipient", text: "kevin@37signals.com"
      assert_selector ".drive-share-dialog__select-all", text: "Select all (3)"
      assert_no_checked_field
      assert_button "Attach only"
      assert_button "Grant view access and attach", disabled: true
    end

    # The token client requested ONLY drive.file, without prior grants.
    init_calls = mock_calls("initTokenCalls")
    assert_equal 1, init_calls.length
    assert_equal DRIVE_FILE_SCOPE, init_calls.first["scope"]
    assert_equal false, init_calls.first["include_granted_scopes"]

    # The Picker was built with the project number, restricted key, OAuth
    # token, and page origin.
    build = mock_calls("pickerBuilds").first
    assert_equal "123456789012", build["appId"]
    assert_equal "test-picker-key", build["developerKey"]
    assert_equal "mock-token-1", build["oauthToken"]
    assert_equal page.evaluate_script("window.location.origin"), build["origin"]
  end

  test "attach-only pins the chip and writes no Drive permissions" do
    inject_drive_share_mocks(drive_scenario)

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") { click_on "Attach only" }

    assert_no_selector ".drive-share-dialog"
    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
    assert_no_selector 'script[src*="google"]', visible: false

    drive_calls = mock_calls("driveCalls")
    assert_equal 1, drive_calls.length, "expected only the files.get capability read"
    assert_match %r{/drive/v3/files/#{FILE_ID}\?}, drive_calls.first["url"]
    assert_includes drive_calls.first["url"], "capabilities"
    assert_equal "Bearer mock-token-1", drive_calls.first["auth"]
    assert_empty drive_calls.select { |call| call["url"].include?("/permissions") }

    # No recipient validation happens on the attach-only path either.
    assert_empty mock_calls("recipientsCalls").select { |call| call["method"] == "POST" }

    click_on "Send Message"

    assert_selector "a.drive-attachment[href='https://drive.google.com/open?id=#{FILE_ID}']"
    assert_equal [ FILE_ID ], Message.last.drive_attachments.map(&:file_id)
    assert_no_selector ".composer__drive-attachments .drive-attachment-chip"
    assert_token_hygiene("mock-token-1")
  end

  test "grant validates, preserves writers, and creates only missing readers" do
    inject_drive_share_mocks(drive_scenario(
      "permissionPages" => [
        [
          { "id" => "perm-david", "type" => "user", "role" => "writer", "emailAddress" => "david@37signals.com" },
          { "id" => "perm-kevin", "type" => "user", "role" => "reader", "emailAddress" => "kevin@37signals.com" }
        ]
      ]
    ))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      find(".drive-share-dialog__select-all input").click
      assert_button "Grant view access and attach", disabled: false
      click_on "Grant view access and attach"

      assert_selector ".drive-share-dialog__summary", exact_text: "All 3 recipients have access: 1 newly granted; 2 already had access. The file is attached below.", wait: 10
      assert_selector ".drive-share-dialog__result--already", text: "already had access", count: 2
      assert_selector ".drive-share-dialog__result--granted", text: "jason@37signals.com"
      click_on "Done"
    end

    # The selection was re-validated against current membership first.
    posts = mock_calls("recipientsCalls").select { |call| call["method"] == "POST" }
    assert_equal 1, posts.length
    assert_includes posts.first["url"], "/drive_recipients/validate"

    # Exactly one sequential reader grant, silent, for the missing member.
    creates = mock_calls("driveCalls").select { |call| call["method"] == "POST" }
    assert_equal [ "jason@37signals.com" ], mock_create_order
    assert_equal 1, creates.length
    assert_includes creates.first["url"], "sendNotificationEmail=false"
    assert_includes creates.first["url"], "supportsAllDrives=true"
    assert_equal(
      { "role" => "reader", "type" => "user", "emailAddress" => "jason@37signals.com" },
      JSON.parse(creates.first["body"])
    )

    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
    assert_token_hygiene("mock-token-1")
  end

  test "partial failure reports per recipient and retries only outstanding grants" do
    inject_drive_share_mocks(drive_scenario(
      "creates" => { "kevin@37signals.com" => { "status" => 403, "reason" => "domainPolicy" } }
    ))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Jason")
      check_recipient("Kevin")
      click_on "Grant view access and attach"

      assert_selector ".drive-share-dialog__summary", text: "granted to 1 of 2", wait: 10
      assert_selector ".drive-share-dialog__result--granted", text: "jason@37signals.com"
      assert_selector ".drive-share-dialog__result--failed", text: "kevin@37signals.com"
      assert_text "organization sharing policy"
    end

    # The file is attached with honest status, never reported as success.
    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"

    page.execute_script("window.__driveShareMock.scenario.creates['kevin@37signals.com'] = 'ok'")
    within(".drive-share-dialog") do
      click_on "Retry 1 remaining"
      assert_selector ".drive-share-dialog__summary", text: "View access granted to 2 recipients", wait: 10
      assert_no_selector ".drive-share-dialog__result--failed"
      click_on "Done"
    end

    # Jason granted once; only Kevin retried, after a fresh permissions
    # re-read converged the ambiguous result.
    assert_equal [ "jason@37signals.com", "kevin@37signals.com", "kevin@37signals.com" ], mock_create_order
    lists = mock_calls("driveCalls").select { |call| call["method"] == "GET" && call["url"].include?("/permissions") }
    assert_operator lists.length, :>=, 2, "expected permissions re-read before retry"
    assert_selector ".composer__drive-attachments .drive-attachment-chip", count: 1
  end

  test "cancelled picker selection shares nothing and can be retried" do
    inject_drive_share_mocks(drive_scenario("picker" => "cancel"))

    find("button.composer__drive-btn").click

    within(".drive-share__panel") do
      assert_text "No file chosen. Nothing was shared."
      assert_button "Choose again"
    end
    assert_empty mock_calls("driveCalls")

    page.execute_script("window.__driveShareMock.scenario.picker = #{drive_scenario['picker'].to_json}")
    within(".drive-share__panel") { click_on "Choose again" }

    assert_selector ".drive-share-dialog", visible: true
    within(".drive-share-dialog") { click_on "Attach only" }
    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
  end

  test "cancelled Google authorization shares nothing and can be retried" do
    inject_drive_share_mocks(drive_scenario("token" => { "error" => "access_denied" }))

    find("button.composer__drive-btn").click

    within(".drive-share__panel") do
      assert_text "Google authorization was cancelled. Nothing was shared."
      assert_button "Try again"
    end
    assert_empty mock_calls("driveCalls")
    assert_empty mock_calls("pickerBuilds")

    page.execute_script("window.__driveShareMock.scenario.token = #{drive_scenario['token'].to_json}")
    within(".drive-share__panel") { click_on "Try again" }

    assert_selector ".drive-share-dialog", visible: true
  end

  test "script load failure offers retry without hanging the composer" do
    page.execute_script(LAZY_MOCK_JS, drive_scenario("failPickerLoad" => true).to_json)

    find("button.composer__drive-btn").click

    within(".drive-share__panel") do
      assert_text "Google Drive could not be reached.", wait: 10
      assert_button "Try again"
    end

    inject_drive_share_mocks(drive_scenario)
    within(".drive-share__panel") { click_on "Try again" }

    assert_selector ".drive-share-dialog", visible: true
  end

  test "first use loads scripts then continues on a fresh gesture" do
    page.execute_script(LAZY_MOCK_JS, drive_scenario.to_json)

    find("button.composer__drive-btn").click

    within(".drive-share__panel") do
      assert_button "Continue with Google", wait: 10
      click_on "Continue with Google"
    end

    assert_selector ".drive-share-dialog", visible: true
    assert_equal 1, mock_calls("requestTokenCalls").length
  end

  test "unshareable file disables the grant but keeps attach-only" do
    file = drive_scenario["file"].merge("capabilities" => { "canShare" => false })
    inject_drive_share_mocks(drive_scenario("file" => file))

    find("button.composer__drive-btn").click

    within(".drive-share-dialog") do
      assert_text "do not have permission to share this file"
      assert_text "organization's Drive policies"
      assert_button "Grant view access and attach", disabled: true
      click_on "Attach only"
    end

    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
    assert_empty mock_calls("driveCalls").select { |call| call["url"].include?("/permissions") }
  end

  test "folder selection disables the grant but keeps attach-only" do
    picker = { "id" => FILE_ID, "name" => "Team folder", "mimeType" => "application/vnd.google-apps.folder" }
    file = picker.merge("capabilities" => { "canShare" => true })
    inject_drive_share_mocks(drive_scenario("picker" => picker, "file" => file))

    find("button.composer__drive-btn").click

    within(".drive-share-dialog") do
      assert_selector ".drive-share-dialog__file", text: "Team folder"
      assert_text "Folders and shortcuts cannot be shared from here"
      assert_button "Grant view access and attach", disabled: true
      click_on "Attach only"
    end

    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Team folder"
    assert_empty mock_calls("driveCalls").select { |call| call["url"].include?("/permissions") }
  end

  test "expired Google session reconnects on an explicit gesture and continues" do
    inject_drive_share_mocks(drive_scenario("failFirstListWith401" => true))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Jason")
      click_on "Grant view access and attach"
      assert_button "Reconnect Google Drive", wait: 10
    end

    page.execute_script("window.__driveShareMock.scenario.token = #{drive_scenario['token'].merge('access_token' => 'mock-token-2').to_json}")
    within(".drive-share-dialog") do
      click_on "Reconnect Google Drive"
      assert_selector ".drive-share-dialog__summary", text: "View access granted", wait: 10
      click_on "Done"
    end

    creates = mock_calls("driveCalls").select { |call| call["method"] == "POST" }
    assert_equal 1, creates.length
    assert_equal "Bearer mock-token-2", creates.first["auth"]
    assert_token_hygiene("mock-token-2")
  end

  test "grant rejects a recipient who left mid-review and refreshes the list" do
    inject_drive_share_mocks(drive_scenario)

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      assert_selector ".drive-share-dialog__recipient", text: "Kevin"
    end

    rooms(:designers).memberships.revoke_from(users(:kevin))

    within(".drive-share-dialog") do
      check_recipient("Kevin")
      check_recipient("David")
      click_on "Grant view access and attach"
      assert_text "no longer in this chat", wait: 10
      assert_no_selector ".drive-share-dialog__recipient", text: "Kevin"
      assert_selector ".drive-share-dialog__recipient", text: "David"
      click_on "Attach only"
    end

    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
    assert_empty mock_calls("driveCalls").select { |call| call["method"] == "POST" }
  end

  test "thread composer grants against the parent room membership" do
    room = rooms(:designers)
    thread = ChannelThread.create!(room:, creator: users(:jz), name: "Drive thread")
    ThreadMembership.join!(thread, users(:jz))
    join_room room
    visit room_url(room, thread: thread.id)
    assert_selector "#thread-panel [data-thread-panel-target='conversation']", visible: true, wait: 10

    inject_drive_share_mocks(drive_scenario)

    within("#thread-panel") do
      find("button.composer__drive-btn", wait: 10).click
    end

    within(".drive-share-dialog") do
      assert_selector ".drive-share-dialog__file", text: "Q3 Planning", wait: 10
      assert_selector ".drive-share-dialog__recipient", text: "david@37signals.com"
      check_recipient("David")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "View access granted", wait: 10
      click_on "Done"
    end

    within("#thread-panel") do
      assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
      fill_in "Write a thread reply", with: "thread file attached"
      click_button "Send Reply"
    end

    assert_selector "#thread-panel a.drive-attachment[href='https://drive.google.com/open?id=#{FILE_ID}']", wait: 10
    assert_equal [ FILE_ID ], thread.messages.order(:id).last.drive_attachments.map(&:file_id)
  end

  test "navigation disposes the dialog, token, and picker state" do
    inject_drive_share_mocks(drive_scenario)

    find("button.composer__drive-btn").click
    assert_selector ".drive-share-dialog", visible: true

    page.execute_script("document.dispatchEvent(new Event('turbo:before-cache'))")

    assert_no_selector ".drive-share-dialog", wait: 5
    assert_no_selector ".drive-share__panel:not([hidden])"
    assert_token_hygiene("mock-token-1")

    within("#sidebar") do
      assert_selector "a", text: "HQ"
      click_link "HQ"
    end
    assert_selector ".room-header__name", text: "HQ", wait: 10
    assert_no_selector ".drive-share-dialog"
    assert_token_hygiene("mock-token-1")
  end

  test "mobile viewport keeps the review dialog usable" do
    page.current_window.resize_to(390, 844)
    begin
      inject_drive_share_mocks(drive_scenario)

      find("button.composer__drive-btn").click

      assert_selector ".drive-share-dialog", visible: true
      assert_selector ".drive-share-dialog__recipient", visible: true
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const dialog = document.querySelector(".drive-share-dialog");
          const rect = dialog.getBoundingClientRect();
          const row = dialog.querySelector(".drive-share-dialog__recipient").getBoundingClientRect();
          return {
            left: rect.left, right: rect.right, width: rect.width,
            viewport: window.innerWidth, rowHeight: row.height
          };
        })()
      JS
      assert_operator geometry["left"], :>=, 0
      assert_operator geometry["right"], :<=, geometry["viewport"]
      assert_operator geometry["rowHeight"], :>=, 44

      within(".drive-share-dialog") { click_on "Attach only" }
      assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
    ensure
      page.current_window.resize_to(1400, 1400)
    end
  end

  test "grant requires fresh review when a recipient email changes" do
    inject_drive_share_mocks(drive_scenario)

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      assert_selector ".drive-share-dialog__recipient", text: "kevin@37signals.com"
    end

    users(:kevin).update_column(:email_address, "kevin.new@37signals.com")

    within(".drive-share-dialog") do
      check_recipient("Kevin")
      click_on "Grant view access and attach"
      assert_text "Recipient details changed since this review", wait: 10
      assert_selector ".drive-share-dialog__recipient", text: "kevin.new@37signals.com"
      assert_no_checked_field
      click_on "Attach only"
    end

    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
    assert_empty mock_calls("driveCalls").select { |call| call["method"] == "POST" }
  end

  test "changed identity can be re-approved against the new email" do
    users(:kevin).update_column(:email_address, "kevin.new@37signals.com")
    inject_drive_share_mocks(drive_scenario)

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Kevin")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "View access granted", wait: 10
      click_on "Done"
    end

    creates = mock_calls("driveCalls").select { |call| call["method"] == "POST" }
    assert_equal [ "kevin.new@37signals.com" ], mock_create_order
    assert_equal 1, creates.length
  end

  test "retry revalidates membership before writing" do
    inject_drive_share_mocks(drive_scenario(
      "creates" => { "kevin@37signals.com" => { "status" => 403, "reason" => "domainPolicy" } }
    ))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Jason")
      check_recipient("Kevin")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "granted to 1 of 2", wait: 10
    end

    rooms(:designers).memberships.revoke_from(users(:kevin))

    within(".drive-share-dialog") do
      click_on "Retry 1 remaining"
      assert_text "no longer in this chat", wait: 10
      assert_no_selector ".drive-share-dialog__recipient", text: "Kevin"
      assert_selector ".drive-share-dialog__recipient", text: "David"
      check_recipient("David")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "View access granted", wait: 10
      click_on "Done"
    end

    assert_equal [ "jason@37signals.com", "kevin@37signals.com", "david@37signals.com" ], mock_create_order
  end

  test "reconnect revalidates before resuming grants" do
    inject_drive_share_mocks(drive_scenario("failFirstListWith401" => true))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Jason")
      check_recipient("Kevin")
      click_on "Grant view access and attach"
      assert_button "Reconnect Google Drive", wait: 10
    end

    rooms(:designers).memberships.revoke_from(users(:kevin))
    page.execute_script("window.__driveShareMock.scenario.token = #{drive_scenario['token'].merge('access_token' => 'mock-token-2').to_json}")

    within(".drive-share-dialog") do
      click_on "Reconnect Google Drive"
      assert_text "no longer in this chat", wait: 10
      assert_no_selector ".drive-share-dialog__recipient", text: "Kevin"
      assert_selector ".drive-share-dialog__recipient", text: "David"
    end

    assert_empty mock_calls("driveCalls").select { |call| call["method"] == "POST" }
  end

  test "cancelled authorization invalidates a delayed token callback" do
    page.execute_script(MOCK_JS, drive_scenario("token" => { "access_token" => "delayed-token" }).to_json)
    page.execute_script(<<~JS)
      const mock = window.__driveShareMock;
      const oauth = window.google.accounts.oauth2;
      const init = oauth.initTokenClient;
      oauth.initTokenClient = (config) => {
        const client = init(config);
        return { requestAccessToken: (override) => {
          mock.requestTokenCalls.push(override || {});
        }};
      };
    JS

    find("button.composer__drive-btn").click
    within(".drive-share__panel") do
      assert_text "Waiting for Google authorization"
      click_on "Cancel"
      assert_text "Google authorization was cancelled. Nothing was shared."
    end

    page.execute_script("window.__driveShareMock.lastTokenConfig.callback({access_token: 'delayed-token'})")

    assert_no_selector ".drive-share-dialog"
    assert_empty mock_calls("pickerBuilds")
    assert_empty mock_calls("driveCalls")
  end

  test "cancelled picker invalidates a delayed selection callback" do
    inject_drive_share_mocks(drive_scenario("picker" => "manual"))

    find("button.composer__drive-btn").click
    within(".drive-share__panel") do
      assert_text "Choose a file in the Google Drive window", wait: 10
      click_on "Cancel"
      assert_text "No file chosen. Nothing was shared."
    end

    page.execute_script(
      "window.__driveShareMock.lastPickerCallback({action: 'picked', docs: [#{drive_scenario['picker'].to_json}]})"
    )

    assert_no_selector ".drive-share-dialog"
    assert_empty mock_calls("driveCalls")
  end

  test "grant is blocked when attachments are already full" do
    page.execute_script(<<~JS)
      const strip = document.querySelector(".composer__drive-attachments");
      for (let i = 0; i < 10; i++) {
        const chip = document.createElement("span");
        chip.className = "drive-attachment-chip";
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = "message[drive_file_ids][]";
        input.value = `prefilled${i}1`;
        chip.append(input);
        strip.append(chip);
      }
    JS
    inject_drive_share_mocks(drive_scenario)

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("David")
      click_on "Grant view access and attach"
      assert_text "remove one to grant and attach", wait: 10
    end

    assert_empty mock_calls("driveCalls").select { |call| call["url"].include?("/permissions") }

    page.execute_script("document.querySelector('.composer__drive-attachments').replaceChildren()")
    within(".drive-share-dialog") do
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "View access granted", wait: 10
      click_on "Done"
    end

    assert_equal [ "david@37signals.com" ], mock_create_order
  end

  test "mid-flight capacity loss preserves grant outcomes" do
    inject_drive_share_mocks(drive_scenario("fillStripOnCreate" => true))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("David")
      check_recipient("Jason")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "not attached yet", wait: 10
      assert_selector ".drive-share-dialog__result--granted", count: 2
      assert_text "Grant results are shown below and are unaffected"
      assert_button "Attach file"
    end

    assert_no_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"

    page.execute_script("document.querySelector('.composer__drive-attachments').replaceChildren()")
    within(".drive-share-dialog") do
      click_on "Attach file"
      assert_selector ".drive-share-dialog__summary", text: "The file is attached below"
      click_on "Done"
    end

    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
  end

  test "rate-limited grants are classified and retry cleanly" do
    inject_drive_share_mocks(drive_scenario(
      "creates" => { "kevin@37signals.com" => { "status" => 429 } }
    ))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Jason")
      check_recipient("Kevin")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "granted to 1 of 2", wait: 10
      assert_selector ".drive-share-dialog__result--failed", text: "rate limited"
      assert_text "rate-limited these grants"
      assert_no_text "Google denied every grant"
    end

    page.execute_script("window.__driveShareMock.scenario.creates['kevin@37signals.com'] = 'ok'")
    within(".drive-share-dialog") do
      click_on "Retry 1 remaining"
      assert_selector ".drive-share-dialog__summary", text: "View access granted to 2 recipients", wait: 10
      click_on "Done"
    end

    assert_equal [ "jason@37signals.com", "kevin@37signals.com", "kevin@37signals.com" ], mock_create_order
  end

  test "dialog checkboxes are visible and long names wrap" do
    User.create!(name: "Alexandria Montgomery-Beauregard the Third of Accounting", email_address: "alexandria.montgomery-beauregard.the.third@37signals.com", password: "secret123456")
      .tap { |user| rooms(:designers).memberships.grant_to(user) }
    inject_drive_share_mocks(drive_scenario)

    find("button.composer__drive-btn").click
    assert_selector ".drive-share-dialog__recipient", text: "Alexandria Montgomery-Beauregard", wait: 10

    styles = page.evaluate_script(<<~JS)
      (() => {
        const box = document.querySelector(".drive-share-dialog__recipient input");
        const name = document.querySelector(".drive-share-dialog__recipient-name");
        const email = document.querySelector(".drive-share-dialog__recipient-email");
        const boxRect = box.getBoundingClientRect();
        const boxStyle = getComputedStyle(box);
        return {
          width: boxRect.width, height: boxRect.height,
          appearance: boxStyle.appearance,
          nameWrap: getComputedStyle(name).overflowWrap,
          nameWhiteSpace: getComputedStyle(name).whiteSpace,
          emailWrap: getComputedStyle(email).overflowWrap
        };
      })()
    JS
    assert_operator styles["width"], :>, 0
    assert_operator styles["height"], :>, 0
    assert_not_equal "none", styles["appearance"]
    assert_equal "anywhere", styles["nameWrap"]
    assert_equal "normal", styles["nameWhiteSpace"]
    assert_equal "anywhere", styles["emailWrap"]
  end

  test "retry does not write while attachment capacity is unavailable" do
    inject_drive_share_mocks(drive_scenario(
      "fillStripOnCreate" => true,
      "creates" => { "kevin@37signals.com" => { "status" => 403, "reason" => "domainPolicy" } }
    ))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Jason")
      check_recipient("Kevin")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "granted to 1 of 2", wait: 10
      assert_selector ".drive-share-dialog__summary", text: "not attached yet"
      assert_button "Attach file"
    end
    assert_equal [ "jason@37signals.com", "kevin@37signals.com" ], mock_create_order
    assert_no_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"

    page.execute_script("window.__driveShareMock.scenario.creates['kevin@37signals.com'] = 'ok'")

    within(".drive-share-dialog") do
      click_on "Retry 1 remaining"
      assert_text "remove one to grant and attach", wait: 10
      assert_selector ".drive-share-dialog__result--granted", text: "jason@37signals.com"
      assert_selector ".drive-share-dialog__result--failed", text: "kevin@37signals.com"
    end

    assert_equal [ "jason@37signals.com", "kevin@37signals.com" ], mock_create_order

    page.execute_script("document.querySelector('.composer__drive-attachments').replaceChildren()")
    within(".drive-share-dialog") do
      click_on "Retry 1 remaining"
      assert_selector ".drive-share-dialog__summary", text: "View access granted to 2 recipients", wait: 10
      assert_selector ".drive-share-dialog__summary", text: "The file is attached below"
      click_on "Done"
    end

    assert_equal [ "jason@37signals.com", "kevin@37signals.com", "kevin@37signals.com" ], mock_create_order
    assert_selector ".composer__drive-attachments .drive-attachment-chip", text: "Q3 Planning"
  end

  test "completed outcomes stay visible through reconnect and refreshed review" do
    inject_drive_share_mocks(drive_scenario("create401OnAttempt" => 2))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("David")
      check_recipient("Jason")
      click_on "Grant view access and attach"
      assert_button "Reconnect Google Drive", wait: 10
      within(".drive-share-dialog__completed") do
        assert_text "persist in Drive even if you cancel"
        assert_selector ".drive-share-dialog__result--granted", text: "david@37signals.com"
      end
      assert_no_selector ".drive-share-dialog__completed .drive-share-dialog__result", text: "jason@37signals.com"
    end

    rooms(:designers).memberships.revoke_from(users(:jason))
    page.execute_script("window.__driveShareMock.scenario.token = #{drive_scenario['token'].merge('access_token' => 'mock-token-2').to_json}")

    within(".drive-share-dialog") do
      click_on "Reconnect Google Drive"
      assert_text "no longer in this chat", wait: 10
      within(".drive-share-dialog__completed") do
        assert_selector ".drive-share-dialog__result--granted", text: "david@37signals.com"
      end
      assert_selector ".drive-share-dialog__recipient", text: "Kevin"
      click_on "Cancel"
    end

    assert_no_selector ".drive-share-dialog"
    assert_equal [ "david@37signals.com", "jason@37signals.com" ], mock_create_order
  end

  test "reconciled access is confirmed, not claimed as newly granted" do
    inject_drive_share_mocks(drive_scenario(
      "creates" => { "kevin@37signals.com" => { "status" => 500 } }
    ))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Jason")
      check_recipient("Kevin")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "granted to 1 of 2", wait: 10
      assert_selector ".drive-share-dialog__result--failed", text: "service error"
    end

    page.execute_script(<<~JS)
      window.__driveShareMock.scenario.permissionPages = [
        [ { id: "perm-kevin", type: "user", role: "reader", emailAddress: "kevin@37signals.com" } ]
      ];
    JS
    within(".drive-share-dialog") do
      click_on "Retry 1 remaining"
      assert_selector ".drive-share-dialog__summary", exact_text: "All 2 recipients have access: 1 newly granted; 1 confirmed in Drive. The file is attached below.", wait: 10
      assert_selector ".drive-share-dialog__result--confirmed", text: "kevin@37signals.com"
      assert_selector ".drive-share-dialog__result--confirmed", text: "access confirmed"
      click_on "Done"
    end

    assert_equal [ "jason@37signals.com", "kevin@37signals.com" ], mock_create_order
  end

  test "existing and reconciled access are distinguished with no new grants" do
    inject_drive_share_mocks(drive_scenario(
      "permissionPages" => [ [ { "id" => "perm-jason", "type" => "user", "role" => "writer", "emailAddress" => "jason@37signals.com" } ] ],
      "creates" => { "kevin@37signals.com" => { "status" => 500 } }
    ))
    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Jason")
      check_recipient("Kevin")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__result--already", text: "jason@37signals.com"
      assert_selector ".drive-share-dialog__result--failed", text: "kevin@37signals.com"
    end
    page.execute_script(<<~JS)
      window.__driveShareMock.scenario.permissionPages = [[
        { id: "perm-jason", type: "user", role: "writer", emailAddress: "jason@37signals.com" },
        { id: "perm-kevin", type: "user", role: "owner", emailAddress: "kevin@37signals.com" }
      ]];
    JS
    within(".drive-share-dialog") do
      click_on "Retry 1 remaining"
      assert_selector ".drive-share-dialog__summary", exact_text: "All 2 recipients have access: 1 already had access; 1 confirmed in Drive. The file is attached below.", wait: 10
      assert_no_selector ".drive-share-dialog__result--granted"
      click_on "Done"
    end
    assert_equal [ "kevin@37signals.com" ], mock_create_order
  end

  test "server errors are classified as service failures, not policy denials" do
    inject_drive_share_mocks(drive_scenario(
      "creates" => { "kevin@37signals.com" => { "status" => 503 } }
    ))

    find("button.composer__drive-btn").click
    within(".drive-share-dialog") do
      check_recipient("Kevin")
      click_on "Grant view access and attach"
      assert_selector ".drive-share-dialog__summary", text: "No access was granted", wait: 10
      assert_selector ".drive-share-dialog__result--failed", text: "service error"
      assert_text "service error"
      assert_no_text "refused by Google"
      assert_no_text "Google denied every grant"
      assert_no_text "sharing policy"
    end

    page.execute_script("window.__driveShareMock.scenario.creates['kevin@37signals.com'] = 'ok'")
    within(".drive-share-dialog") do
      click_on "Retry 1 remaining"
      assert_selector ".drive-share-dialog__summary", text: "View access granted", wait: 10
      click_on "Done"
    end

    assert_equal [ "kevin@37signals.com", "kevin@37signals.com" ], mock_create_order
  end

  private
    def drive_scenario(overrides = {})
      {
        "token" => {
          "access_token" => "mock-token-1", "token_type" => "Bearer",
          "expires_in" => 3600, "scope" => DRIVE_FILE_SCOPE
        },
        "picker" => { "id" => FILE_ID, "name" => "Q3 Planning", "mimeType" => "application/vnd.google-apps.document" },
        "file" => {
          "id" => FILE_ID, "name" => "Q3 Planning",
          "mimeType" => "application/vnd.google-apps.document",
          "capabilities" => { "canShare" => true }
        },
        "permissionPages" => [ [] ],
        "creates" => {},
        "failFirstListWith401" => false
      }.merge(overrides)
    end

    def inject_drive_share_mocks(scenario)
      page.execute_script(MOCK_JS, scenario.to_json)
    end

    def mock_calls(name)
      page.evaluate_script("window.__driveShareMock.#{name}")
    end

    def mock_create_order
      page.evaluate_script("window.__driveShareMock.createOrder")
    end

    def check_recipient(name)
      find(".drive-share-dialog__recipient", text: name).find("input").click
    end

    # The ephemeral token must never reach HTML, meta tags, storage, or
    # observable request state outside the Google Authorization header.
    def assert_no_checked_field
      assert_equal 0, page.evaluate_script(
        "document.querySelectorAll('.drive-share-dialog input:checked').length"
      )
    end

    def assert_token_hygiene(token)
      assert_not_includes page.evaluate_script("document.documentElement.outerHTML"), token
      storage = page.evaluate_script("[JSON.stringify({...localStorage}), JSON.stringify({...sessionStorage})].join(' ')")
      assert_not_includes storage, token
    end
end
