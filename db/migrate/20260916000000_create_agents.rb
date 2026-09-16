class CreateAgents < ActiveRecord::Migration[8.2]
  def change
    create_table :agents do |t|
      t.integer :user_id, null: false
      t.integer :owner_id
      t.string :kind, null: false, default: "personal"
      t.string :provider, :runtime, :description
      t.datetime :suspended_at
      t.timestamps

      t.index :user_id, unique: true
      t.index [ :owner_id, :kind ]
    end

    reversible do |dir|
      dir.up do
        backfill_agents_for_existing_bots
      end
    end
  end

  def backfill_agents_for_existing_bots
    execute <<~SQL.squish
      INSERT INTO agents (user_id, owner_id, kind, created_at, updated_at)
      SELECT id, NULL, 'workspace', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM users WHERE role = #{User.roles.fetch("bot")}
    SQL
  end
end
