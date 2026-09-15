class AddMessageConversations < ActiveRecord::Migration[8.2]
  def change
    create_table :channel_threads do |t|
      t.integer :room_id, null: false
      t.integer :creator_id, null: false
      t.integer :parent_message_id
      t.string :name, null: false
      t.integer :auto_archive_after_minutes, null: false, default: 4320
      t.datetime :last_activity_at, null: false
      t.datetime :closed_at
      t.datetime :locked_at
      t.timestamps

      t.index [ :room_id, :last_activity_at ]
      t.index [ :room_id, :closed_at, :locked_at ]
      t.index :creator_id
      t.index :parent_message_id, unique: true, where: "parent_message_id IS NOT NULL"
    end

    add_foreign_key :channel_threads, :rooms
    add_foreign_key :channel_threads, :users, column: :creator_id
    add_foreign_key :channel_threads, :messages, column: :parent_message_id, on_delete: :nullify

    create_table :thread_memberships do |t|
      t.integer :thread_id, null: false
      t.integer :user_id, null: false
      t.string :involvement, null: false, default: "mentions"
      t.datetime :unread_at
      t.datetime :joined_at, null: false
      t.timestamps

      t.index [ :thread_id, :user_id ], unique: true
      t.index :user_id
      t.index [ :thread_id, :unread_at ]
    end

    add_foreign_key :thread_memberships, :channel_threads, column: :thread_id, on_delete: :cascade
    add_foreign_key :thread_memberships, :users, on_delete: :cascade

    add_column :messages, :thread_id, :integer
    add_column :messages, :reply_to_message_id, :integer
    add_column :messages, :reply_notify_author, :boolean, null: false, default: true
    add_column :messages, :reply_target_deleted_at, :datetime
    add_column :messages, :forwarded_from_message_id, :integer
    add_column :messages, :forwarded_at, :datetime
    add_column :messages, :forward_note, :text

    add_index :messages, :thread_id
    add_index :messages, :reply_to_message_id
    add_index :messages, :forwarded_from_message_id
    add_foreign_key :messages, :channel_threads, column: :thread_id, on_delete: :cascade
    add_foreign_key :messages, :messages, column: :reply_to_message_id, on_delete: :nullify
    add_foreign_key :messages, :messages, column: :forwarded_from_message_id, on_delete: :nullify
  end
end
