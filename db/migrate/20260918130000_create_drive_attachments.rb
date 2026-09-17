class CreateDriveAttachments < ActiveRecord::Migration[8.2]
  def change
    create_table :drive_attachments do |t|
      t.references :message, null: false, foreign_key: true
      t.string :file_id, null: false

      t.datetime :created_at, null: false
    end
    add_index :drive_attachments, %i[ message_id file_id ], unique: true
  end
end
