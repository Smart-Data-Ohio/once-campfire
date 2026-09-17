class AddStageRolesToMembershipsAndHuddleGrants < ActiveRecord::Migration[8.2]
  def change
    add_column :memberships, :stage_role, :string
    add_column :memberships, :hand_raised_at, :datetime
    add_column :huddle_grants, :stage_role, :string

    add_index :memberships, [ :room_id, :stage_role ]
  end
end
