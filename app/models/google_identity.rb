# A member's stable Google sign-in identity (Workspace OIDC subject).
# Separate from GoogleAccount, which is the optional Calendar/Drive
# connection: disconnecting Calendar never touches this row, and a
# Calendar connection is never treated as login identity. The subject
# is immutable at Google, so it stays linked across email changes.
class GoogleIdentity < ApplicationRecord
  belongs_to :user

  validates :subject, presence: true, uniqueness: true
  validates :user_id, uniqueness: true
  validates :email, presence: true
end
