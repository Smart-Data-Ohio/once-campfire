class CreateAgentCredentials < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_credentials do |t|
      t.integer :agent_id, null: false
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_last_four, null: false
      t.datetime :last_used_at, :expires_at, :revoked_at
      t.string :last_used_ip
      t.integer :created_by_id, null: false
      t.timestamps

      t.index :token_digest, unique: true
      t.index [ :agent_id, :revoked_at ]
    end
  end
end
