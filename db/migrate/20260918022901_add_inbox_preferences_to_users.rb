class AddInboxPreferencesToUsers < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :inbox_preferences, :json, default: {}
  end
end
