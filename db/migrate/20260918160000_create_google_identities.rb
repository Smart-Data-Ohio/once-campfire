class CreateGoogleIdentities < ActiveRecord::Migration[8.2]
  def change
    create_table :google_identities do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :subject, null: false
      t.string :email, null: false
      t.string :domain

      t.timestamps
    end

    add_index :google_identities, :subject, unique: true
  end
end
