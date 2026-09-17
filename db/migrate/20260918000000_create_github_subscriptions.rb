class CreateGithubSubscriptions < ActiveRecord::Migration[8.2]
  def change
    create_table :github_repository_subscriptions do |t|
      t.references :room, null: false, foreign_key: { on_delete: :cascade }
      t.string :owner, null: false
      t.string :repo, null: false
      t.json :events, null: false, default: []
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }

      t.timestamps
    end
    add_index :github_repository_subscriptions, %i[ room_id owner repo ],
      unique: true, name: "index_github_subscriptions_on_room_and_repo"
    add_index :github_repository_subscriptions, %i[ owner repo ],
      name: "index_github_subscriptions_on_owner_and_repo"

    create_table :github_notifications do |t|
      t.references :subscription, null: false,
        foreign_key: { to_table: :github_repository_subscriptions, on_delete: :cascade }
      t.string :dedupe_key, null: false
      t.references :message, foreign_key: { on_delete: :nullify }

      t.timestamps
    end
    add_index :github_notifications, %i[ subscription_id dedupe_key ],
      unique: true, name: "index_github_notifications_on_subscription_and_key"

    add_column :users, :github_login, :string
    add_index :users, :github_login, unique: true
  end
end
