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

  def test_accepts_added_foreign_key_when_existing_constraint_ids_change
    add_child_table_to_both("FOREIGN KEY (creator_id) REFERENCES users(id)")
    rebuild_child_table_after("FOREIGN KEY (creator_id) REFERENCES users(id), FOREIGN KEY (message_id) REFERENCES messages(id)")

    output, error, status = run_verifier

    assert status.success?, output + error
    assert_includes output, "children: rows 0 -> 0, schema MATCH, data MATCH"
  end

  def test_rejects_changed_foreign_key_delete_action
    add_child_table_to_both("FOREIGN KEY (creator_id) REFERENCES users(id) ON DELETE CASCADE")
    rebuild_child_table_after("FOREIGN KEY (creator_id) REFERENCES users(id) ON DELETE SET NULL")

    output, _error, status = run_verifier

    refute status.success?
    assert_includes output, "children: preexisting schema changed MISMATCH"
  end

  def test_rejects_removed_foreign_key
    add_child_table_to_both("FOREIGN KEY (creator_id) REFERENCES users(id), FOREIGN KEY (message_id) REFERENCES messages(id)")
    rebuild_child_table_after("FOREIGN KEY (creator_id) REFERENCES users(id)")

    output, _error, status = run_verifier

    refute status.success?
    assert_includes output, "children: preexisting schema changed MISMATCH"
  end

  def test_rejects_splitting_a_composite_foreign_key_into_separate_constraints
    add_child_table_to_both("FOREIGN KEY (creator_id, message_id) REFERENCES users(id, email_address)")
    rebuild_child_table_after("FOREIGN KEY (creator_id) REFERENCES users(id), FOREIGN KEY (message_id) REFERENCES users(email_address)")

    output, _error, status = run_verifier

    refute status.success?
    assert_includes output, "children: preexisting schema changed MISMATCH"
  end

  private
    def add_child_table_to_both(constraints)
      [ @before_path, @after_path ].each do |path|
        SQLite3::Database.new(path) do |database|
          database.execute("CREATE TABLE children (id INTEGER PRIMARY KEY, creator_id INTEGER, message_id INTEGER, #{constraints})")
        end
      end
    end

    def rebuild_child_table_after(constraints)
      update_after do |database|
        database.execute("DROP TABLE children")
        database.execute("CREATE TABLE children (id INTEGER PRIMARY KEY, creator_id INTEGER, message_id INTEGER, #{constraints})")
      end
    end

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
