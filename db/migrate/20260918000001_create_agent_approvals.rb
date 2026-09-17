class CreateAgentApprovals < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_approvals do |t|
      t.integer :agent_id, null: false
      t.integer :room_id
      t.integer :agent_credential_id
      t.string :action, null: false
      t.text :summary, null: false
      t.text :payload
      t.string :external_id
      t.string :status, null: false, default: "pending"
      t.datetime :expires_at, null: false
      t.integer :decided_by_id
      t.datetime :decided_at
      t.string :decision_note
      t.timestamps
    end

    add_index :agent_approvals, [ :agent_id, :status ]
    add_index :agent_approvals, [ :agent_id, :external_id ], unique: true, where: "external_id IS NOT NULL"
  end
end
