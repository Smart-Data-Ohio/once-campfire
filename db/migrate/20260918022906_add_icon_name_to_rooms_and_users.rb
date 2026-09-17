class AddIconNameToRoomsAndUsers < ActiveRecord::Migration[8.2]
  def change
    add_column :rooms, :icon_name, :string
    add_column :users, :icon_name, :string
  end
end
