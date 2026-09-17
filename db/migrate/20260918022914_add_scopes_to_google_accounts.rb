# Originally numbered 20260917040549 (now 20260918022914), which sorted before the migration that
# creates google_accounts and so failed on any database migrating through the
# chain (the first production release after both merged). Databases that
# loaded db/schema.rb already have the column, hence the guard.
class AddScopesToGoogleAccounts < ActiveRecord::Migration[8.2]
  def change
    add_column :google_accounts, :scopes, :string unless column_exists?(:google_accounts, :scopes)
  end
end
