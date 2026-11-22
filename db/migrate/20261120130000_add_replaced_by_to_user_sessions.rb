# Refresh-token rotation revokes the old session and creates a new one. If the
# response carrying the new token is lost (timeout, app killed, connection
# drop), the client retries with the old token and was logged out. Recording
# which session replaced which lets Auth::RefreshTokens accept that retry for
# a short grace window, only while the replacement is still active.
#
# family_id groups every session descended from one sign-in. When a rotated
# token is replayed after the grace window (a sign it was copied), the whole
# family is revoked, so a stolen token can't keep a session alive
# (refresh-token reuse detection, OAuth 2.0 Security BCP / RFC 9700 4.14.2).
class AddReplacedByToUserSessions < ActiveRecord::Migration[7.2]
  def change
    add_reference :user_sessions, :replaced_by, foreign_key: { to_table: :user_sessions }, null: true
    add_column :user_sessions, :family_id, :string
    add_index :user_sessions, :family_id
  end
end
