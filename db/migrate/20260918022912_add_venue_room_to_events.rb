class AddVenueRoomToEvents < ActiveRecord::Migration[8.2]
  def change
    add_column :events, :venue_room_id, :integer
    add_index :events, :venue_room_id
  end
end
