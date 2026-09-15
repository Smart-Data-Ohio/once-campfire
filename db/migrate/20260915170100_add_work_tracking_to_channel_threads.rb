class AddWorkTrackingToChannelThreads < ActiveRecord::Migration[8.2]
  def change
    add_column :channel_threads, :work_status, :string
    add_column :channel_threads, :work_owner_id, :integer

    add_index :channel_threads, [ :room_id, :work_status, :last_activity_at ],
      name: "index_channel_threads_on_room_and_work_status_and_activity"
    add_index :channel_threads, :work_owner_id
    add_foreign_key :channel_threads, :users, column: :work_owner_id, on_delete: :nullify

    create_table :work_thread_events do |t|
      t.references :channel_thread, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :event_type, null: false
      t.string :from_status
      t.string :to_status
      t.integer :from_owner_id
      t.integer :to_owner_id
      t.string :from_owner_name
      t.string :to_owner_name
      t.json :metadata
      t.timestamps

      t.index [ :channel_thread_id, :created_at ], name: "index_work_thread_events_on_thread_and_created_at"
      t.index [ :event_type, :created_at ], name: "index_work_thread_events_on_type_and_created_at"
    end
  end
end
