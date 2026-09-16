class CreateAgentGrants < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_grants do |t|
      t.integer :agent_id, null: false
      t.integer :room_id
      t.string :capability, null: false
      t.integer :granted_by_id, null: false
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :agent_grants, [ :agent_id, :room_id, :capability ],
      unique: true, where: "revoked_at IS NULL", name: "index_agent_grants_on_agent_room_capability_active"
    add_index :agent_grants, [ :agent_id, :revoked_at ]
  end
end
