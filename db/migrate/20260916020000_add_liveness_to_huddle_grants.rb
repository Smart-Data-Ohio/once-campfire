class AddLivenessToHuddleGrants < ActiveRecord::Migration[8.2]
  def change
    add_column :huddle_grants, :last_seen_at, :datetime
    add_column :huddle_grants, :last_issued_at, :datetime
    add_index :huddle_grants, [ :room_id, :last_seen_at ], name: "index_huddle_grants_on_room_and_last_seen_at"
    add_index :activity_items, [ :event_type, :created_at ], name: "index_activity_items_on_event_type_and_created_at"

    reversible do |direction|
      direction.up do
        HuddleGrant.where(last_issued_at: nil).update_all("last_issued_at = created_at")
      end
    end
  end
end
