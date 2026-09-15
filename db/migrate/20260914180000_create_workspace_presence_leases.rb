class CreateWorkspacePresenceLeases < ActiveRecord::Migration[8.2]
  def change
    create_table :workspace_presence_leases do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :session, null: false, foreign_key: { on_delete: :cascade }
      t.string :connection_id, null: false
      t.datetime :expires_at, null: false
      t.timestamps

      t.index :connection_id, unique: true
      t.index :expires_at
    end
  end
end
