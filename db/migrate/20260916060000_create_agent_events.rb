class CreateAgentEvents < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_events do |t|
      t.integer :agent_id, null: false
      t.string :event_type, null: false
      t.integer :room_id, :message_id, :agent_credential_id, :actor_id
      t.string :outcome, :detail
      t.json :metadata
      t.datetime :created_at, null: false
    end

    add_index :agent_events, [ :agent_id, :created_at ]
  end
end
