class AddScopesToGoogleAccounts < ActiveRecord::Migration[8.2]
  def change
    add_column :google_accounts, :scopes, :string
  end
end
