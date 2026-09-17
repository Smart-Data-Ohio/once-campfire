class CreateGithubConnectedAccounts < ActiveRecord::Migration[8.2]
  def change
    create_table :github_connected_accounts do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :github_login, null: false
      t.string :access_token, null: false
      t.string :disconnected_reason
      t.timestamps
    end
  end
end
