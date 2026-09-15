class CreateActivityItems < ActiveRecord::Migration[8.2]
  def change
    create_table :activity_items do |t|
      t.integer :user_id, null: false
      t.string :source_type, null: false
      t.integer :source_id, null: false
      t.string :event_type, null: false
      t.datetime :read_at
      t.datetime :handled_at
      t.timestamps

      t.index [ :user_id, :source_type, :source_id ], unique: true, name: "index_activity_items_on_user_and_source"
      t.index [ :source_type, :source_id ], name: "index_activity_items_on_source"
      t.index [ :user_id, :read_at, :handled_at, :created_at ], name: "index_activity_items_on_user_and_state"
    end

    add_foreign_key :activity_items, :users, on_delete: :cascade
  end
end
