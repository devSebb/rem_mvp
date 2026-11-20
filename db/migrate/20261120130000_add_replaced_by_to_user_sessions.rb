# Refresh-token rotation revokes the old session and creates a new one. If the
# response carrying the new token is lost (timeout, app killed, connection
# drop), the client retries with the old token and was logged out. Recording
# which session replaced which lets Auth::RefreshTokens accept that retry for
# a short grace window, only while the replacement is still active.
class AddReplacedByToUserSessions < ActiveRecord::Migration[7.2]
  def change
    add_reference :user_sessions, :replaced_by, foreign_key: { to_table: :user_sessions }, null: true
  end
end
