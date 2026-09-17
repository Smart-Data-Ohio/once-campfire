class CreateWorkspaceIcons < ActiveRecord::Migration[8.2]
  def change
    create_table :workspace_icons do |t|
      t.string :name, null: false
      t.string :title, null: false
      t.references :creator, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end
    add_index :workspace_icons, :name, unique: true
  end
end
