require "test_helper"

class Accounts::IconsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "index lists icons with previews shortcodes titles and uploaders" do
    icon = create_workspace_icon(name: "acme", title: "Acme Corp")

    get account_icons_url

    assert_response :success
    assert_select "img[src=?]", workspace_icon_path(name: "acme")
    assert_select "code", text: ":acme:"
    assert_match "Acme Corp", response.body
    assert_match "Uploaded by #{icon.creator.name}", response.body
  end

  test "create uploads an icon" do
    assert_difference "WorkspaceIcon.count", 1 do
      post account_icons_url, params: {
        workspace_icon: {
          name: "acme", title: "Acme Corp",
          image: fixture_file_upload("workspace_icons/clean.svg", "image/svg+xml")
        }
      }

      assert_redirected_to account_icons_url
    end

    icon = WorkspaceIcon.find_by!(name: "acme")

    assert_equal "Acme Corp", icon.title
    assert_equal users(:david), icon.creator
    assert icon.image.attached?
  end

  test "create renders validation errors inline" do
    assert_no_difference "WorkspaceIcon.count" do
      post account_icons_url, params: {
        workspace_icon: {
          name: "openai", title: "",
          image: fixture_file_upload("workspace_icons/script.svg", "image/svg+xml")
        }
      }

      assert_response :unprocessable_entity
    end

    assert_match "already taken by a built-in icon", response.body
  end

  test "destroy removes the icon and its blob" do
    icon = create_workspace_icon(name: "acme")

    perform_enqueued_jobs do
      assert_difference [ "WorkspaceIcon.count", "ActiveStorage::Blob.count" ], -1 do
        delete account_icon_url(icon)

        assert_redirected_to account_icons_url
      end
    end
  end

  test "members get forbidden on list create and delete" do
    icon = create_workspace_icon(name: "acme")
    sign_in :jz

    get account_icons_url
    assert_response :forbidden

    post account_icons_url, params: {
      workspace_icon: {
        name: "nope", title: "Nope",
        image: fixture_file_upload("workspace_icons/clean.svg", "image/svg+xml")
      }
    }
    assert_response :forbidden

    delete account_icon_url(icon)
    assert_response :forbidden

    assert WorkspaceIcon.exists?(icon.id)
  end
end
