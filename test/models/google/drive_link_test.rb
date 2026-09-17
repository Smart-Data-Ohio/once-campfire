require "test_helper"

class Google::DriveLinkTest < ActiveSupport::TestCase
  test "docs editor URLs" do
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://docs.google.com/document/d/1AbcDefGhIjKlMnOpQrSt/edit")
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://docs.google.com/spreadsheets/d/1AbcDefGhIjKlMnOpQrSt/edit#gid=0")
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://docs.google.com/presentation/d/1AbcDefGhIjKlMnOpQrSt/edit")
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://docs.google.com/forms/d/1AbcDefGhIjKlMnOpQrSt/viewform")
  end

  test "drive file, open, and folder URLs" do
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view?usp=sharing")
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://drive.google.com/open?id=1AbcDefGhIjKlMnOpQrSt")
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://drive.google.com/open?usp=sharing&id=1AbcDefGhIjKlMnOpQrSt")
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://drive.google.com/drive/folders/1AbcDefGhIjKlMnOpQrSt")
  end

  test "account switcher prefixes" do
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://docs.google.com/document/u/0/d/1AbcDefGhIjKlMnOpQrSt/edit")
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://drive.google.com/drive/u/2/folders/1AbcDefGhIjKlMnOpQrSt")
    assert_equal "1AbcDefGhIjKlMnOpQrSt", Google::DriveLink.file_id("https://drive.google.com/u/0/open?id=1AbcDefGhIjKlMnOpQrSt")
  end

  test "negatives" do
    assert_nil Google::DriveLink.file_id("https://example.com/document/d/1AbcDefGhIjKlMnOpQrSt/edit")
    assert_nil Google::DriveLink.file_id("https://docs.google.com.evil.test/document/d/1AbcDefGhIjKlMnOpQrSt/edit")
    assert_nil Google::DriveLink.file_id("https://docs.google.com/document/d//edit")
    assert_nil Google::DriveLink.file_id("https://docs.google.com/document/d/short/edit")
    assert_nil Google::DriveLink.file_id("https://drive.google.com/open?id=")
    assert_nil Google::DriveLink.file_id("https://drive.google.com/drive/folders/")
    assert_nil Google::DriveLink.file_id("javascript:alert(document.cookie)")
    assert_nil Google::DriveLink.file_id(nil)
    assert_nil Google::DriveLink.file_id("")
  end

  test "valid_id? accepts bare file ids only" do
    assert Google::DriveLink.valid_id?("1AbcDefGhIjKlMnOpQrSt")
    assert Google::DriveLink.valid_id?("abc_def-123XYZ")
    assert_not Google::DriveLink.valid_id?("short")
    assert_not Google::DriveLink.valid_id?("has spaces in it!!")
    assert_not Google::DriveLink.valid_id?("https://drive.google.com/open?id=1AbcDefGhIjKlMnOpQrSt")
    assert_not Google::DriveLink.valid_id?(nil)
  end
end
