require "test_helper"

class RoomAndBotIconsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "sidebar rows show the room icon when set and the plain marker otherwise" do
    rooms(:pets).update!(icon_name: "openai")

    get user_sidebar_url
    assert_response :success

    assert_select "##{dom_id(rooms(:pets), :list)} .sidebar-item__icon--custom img.icon-avatar[src='#{icon_src}']"
    assert_select "##{dom_id(rooms(:hq), :list)} .sidebar-item__icon:not(.sidebar-item__icon--custom)"
    assert_select "##{dom_id(rooms(:hq), :list)} img", count: 0
  end

  test "room header shows the icon when set and the hash otherwise" do
    rooms(:pets).update!(icon_name: "openai")

    get room_url(rooms(:pets))
    assert_response :success
    assert_select ".room-header__identity img.icon-avatar[src='#{icon_src}']"
    assert_select ".room-header__hash", count: 0

    get room_url(rooms(:hq))
    assert_response :success
    assert_select ".room-header__hash", text: "#"
    assert_select ".room-header__identity img", count: 0
  end

  test "a deleted workspace icon falls back to the plain marker without raising" do
    create_workspace_icon(name: "acme")
    rooms(:pets).update!(icon_name: "acme")
    WorkspaceIcon.find_by!(name: "acme").destroy

    get user_sidebar_url
    assert_response :success
    assert_select "##{dom_id(rooms(:pets), :list)} .sidebar-item__icon:not(.sidebar-item__icon--custom)"
    assert_select "##{dom_id(rooms(:pets), :list)} img", count: 0

    get room_url(rooms(:pets))
    assert_response :success
    assert_select ".room-header__hash", text: "#"
  end

  test "search results show the room icon in place of the arrow marker" do
    rooms(:designers).update!(icon_name: "openai")
    rooms(:designers).messages.create!(body: "Hello world!", client_message_id: "search-icon", creator: users(:david))

    get searches_url, params: { q: "hello" }
    assert_response :success
    assert_select "#search-results .message__room--custom img.icon-avatar[src='#{icon_src}']"
  end

  test "search results keep the plain marker without an icon" do
    rooms(:designers).messages.create!(body: "Hello world!", client_message_id: "search-plain", creator: users(:david))

    get searches_url, params: { q: "hello" }
    assert_response :success
    assert_select "#search-results .message__room:not(.message__room--custom)"
    assert_select "#search-results .message__room img", count: 0
  end

  test "bot messages show the icon avatar when set" do
    users(:bender).update!(icon_name: "openai")
    message = rooms(:watercooler).messages.create!(creator: users(:bender), body: "Beep", client_message_id: "bot-icon-1")

    get room_url(rooms(:watercooler))
    assert_response :success
    assert_select "##{dom_id(message)} .message__avatar img.icon-avatar[src='#{icon_src}']"
  end

  test "an uploaded bot picture wins over the icon" do
    users(:bender).update!(icon_name: "openai")
    users(:bender).avatar.attach io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"
    message = rooms(:watercooler).messages.create!(creator: users(:bender), body: "Beep", client_message_id: "bot-icon-2")

    get room_url(rooms(:watercooler))
    assert_response :success
    assert_select "##{dom_id(message)} .message__avatar img.icon-avatar", count: 0
    assert_select "##{dom_id(message)} .message__avatar img[src*='/avatar']", count: 1
  end

  test "bot messages without an icon keep the default avatar" do
    message = rooms(:watercooler).messages.create!(creator: users(:bender), body: "Beep", client_message_id: "bot-icon-3")

    get room_url(rooms(:watercooler))
    assert_response :success
    assert_select "##{dom_id(message)} .message__avatar img.icon-avatar", count: 0
    assert_select "##{dom_id(message)} .message__avatar img[src*='/avatar']", count: 1
  end

  test "a human icon_name does not change their avatar" do
    users(:david).update!(icon_name: "openai")
    message = rooms(:watercooler).messages.create!(creator: users(:david), body: "Hi", client_message_id: "human-icon-1")

    get room_url(rooms(:watercooler))
    assert_response :success
    assert_select "##{dom_id(message)} .message__avatar img.icon-avatar", count: 0
  end

  test "room edit form shows the icon field with the shortcode and preview" do
    rooms(:pets).update!(icon_name: "openai")

    get edit_rooms_open_url(rooms(:pets))
    assert_response :success
    assert_select "input[name='room[icon_name]'][value=':openai:']"
    assert_select "[data-icon-field-target='preview'] img.icon-avatar[src='#{icon_src}']"
    assert_select "[data-controller='icon-field'] button", text: "Remove"
  end

  test "room edit form hides the icon field from non-administrators" do
    sign_in :jz

    get edit_rooms_open_url(rooms(:hq))
    assert_response :success
    assert_select "input[name='room[icon_name]']", count: 0
  end

  test "bot edit form shows the icon field" do
    get edit_account_bot_url(users(:bender))
    assert_response :success
    assert_select "input[name='user[icon_name]']"
    assert_select "[data-controller='icon-field'] button", text: "Remove"
  end

  private
    def icon_src
      Icons.brand_image_urls.fetch("openai")
    end

    def dom_id(*arguments)
      ActionView::RecordIdentifier.dom_id(*arguments)
    end
end
