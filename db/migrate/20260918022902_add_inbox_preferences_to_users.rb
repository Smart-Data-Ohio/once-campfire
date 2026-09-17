class AddInboxPreferencesToUsers < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :inbox_preferences, :json, default: {}
    add_index :activity_items, [ :user_id, :updated_at ]
  end
end
