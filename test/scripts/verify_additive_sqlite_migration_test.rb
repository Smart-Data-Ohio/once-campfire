require "minitest/autorun"
require "fileutils"
require "open3"
require "sqlite3"
require "tmpdir"

class VerifyAdditiveSqliteMigrationTest < Minitest::Test
  SCRIPT = File.expand_path("../../script/admin/verify-additive-sqlite-migration", __dir__)

  def setup
    @directory = Dir.mktmpdir
    @before_path = File.join(@directory, "before.sqlite3")
    @after_path = File.join(@directory, "after.sqlite3")

    database = SQLite3::Database.new(@before_path)
    database.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email_address TEXT NOT NULL UNIQUE)")
    database.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, body BLOB)")
    database.execute("INSERT INTO users VALUES (?, ?)", [ 7, "private@example.test" ])
    database.execute("INSERT INTO messages VALUES (?, ?)", [ 93, SQLite3::Blob.new("private message") ])
    database.close

    FileUtils.cp(@before_path, @after_path)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_accepts_new_tables_and_columns_when_existing_values_are_unchanged
    update_after do |database|
      database.execute("ALTER TABLE messages ADD COLUMN markdown_source TEXT")
      database.execute("CREATE TABLE huddle_grants (id INTEGER PRIMARY KEY)")
    end

    output, error, status = run_verifier

    assert status.success?, output + error
    assert_includes output, "MATCH: 2 preexisting tables preserved"
    assert_includes output, "ADDITIVE: 1 tables, 1 columns"
  end

  def test_rejects_changed_values_without_printing_them
    update_after do |database|
      database.execute("UPDATE users SET email_address = ? WHERE id = 7", "changed@example.test")
      database.execute("UPDATE messages SET body = ? WHERE id = 93", "changed private message")
    end

    output, error, status = run_verifier

    refute status.success?
    assert_includes output, "preexisting row data changed MISMATCH"
    refute_includes output + error, "private@example.test"
    refute_includes output + error, "changed private message"
  end

  def test_rejects_removed_schema
    update_after { |database| database.execute("DROP TABLE messages") }

    output, _error, status = run_verifier

    refute status.success?
    assert_includes output, "messages: table is missing MISMATCH"
  end

  def test_rejects_comparing_a_database_with_itself
    output, _error, status = Open3.capture3(Gem.ruby, SCRIPT, @before_path, @before_path)

    refute status.success?
    assert_includes output, "before and after must be separate database files"
  end

  private
    def update_after
      database = SQLite3::Database.new(@after_path)
      yield database
    ensure
      database&.close
    end

    def run_verifier
      Open3.capture3(Gem.ruby, SCRIPT, @before_path, @after_path)
    end
end
