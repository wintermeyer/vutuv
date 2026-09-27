# Builds (and resets) the one fictional member the PDF trailer shows, in the
# local dev database only.
#
#   mix run --no-start scripts/pdf_trailer/seed.exs
#
# Idempotent: run it before every recording. Clara Neumann starts with no
# posts, no draft and no pending files, so every take begins the same way.
Application.put_env(:vutuv, :fediverse_enabled, false, persistent: true)
Application.put_env(:vutuv, :web_push_enabled, false, persistent: true)
Application.put_env(:vutuv, :moderate_images, false, persistent: true)
Application.put_env(:vutuv, :generate_screenshots, false, persistent: true)
Application.put_env(:phoenix, :serve_endpoints, false, persistent: true)
{:ok, _} = Application.ensure_all_started(:vutuv)

import Ecto.Query
alias Vutuv.{Accounts, Repo}
alias Vutuv.Accounts.User

username = "clara_neumann"

unless Repo.exists?(from(u in User, where: u.username == ^username)) do
  conn = Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("accept-language", "de")

  {:ok, u} =
    Accounts.register_user(conn, %{
      "first_name" => "Clara",
      "last_name" => "Neumann",
      "emails" => %{"0" => %{"value" => "clara.neumann@example.com"}},
      "tag_list" => "Handwerk, Holzbau, Veranstaltungen"
    })

  if u.username != username, do: raise("became @#{u.username}, expected @#{username}")
  IO.puts("SEED created @#{username}")
end

Repo.query!(
  ~s|update users set "email_confirmed?" = true, locale = 'de', inserted_at = least(inserted_at, now() - interval '60 days') where username = $1|,
  [username]
)

clara = Repo.one!(from(u in User, where: u.username == ^username))

# a clean slate: no posts, no draft, nothing waiting, no loose files
for post <- Repo.all(from(p in Vutuv.Posts.Post, where: p.user_id == ^clara.id)),
    do: Vutuv.Posts.delete_post(post)

Repo.delete_all(from(d in Vutuv.Posts.PostDraft, where: d.user_id == ^clara.id))
Repo.delete_all(from(p in Vutuv.Posts.PendingPost, where: p.user_id == ^clara.id))

for a <- Repo.all(from(a in Vutuv.Attachments.Attachment, where: a.user_id == ^clara.id)),
    do: Vutuv.Attachments.purge(a)

IO.puts("SEED ready @#{username} id=#{clara.id}")
