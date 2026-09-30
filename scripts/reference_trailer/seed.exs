# Builds (and resets) the one fictional member the Arbeitszeugnis trailer
# shows, in the local dev database only.
#
#   mix run --no-start scripts/reference_trailer/seed.exs
#
# Idempotent: run it before every recording. Friedhelm Pöttering is the
# fictional Lagermeister of the upstream skill's test file 04, so the name on
# the account and the name in the Zeugnis agree. Every take starts with no
# reference and no check.
Application.put_env(:vutuv, :fediverse_enabled, false, persistent: true)
Application.put_env(:vutuv, :web_push_enabled, false, persistent: true)
Application.put_env(:vutuv, :moderate_images, false, persistent: true)
Application.put_env(:vutuv, :generate_screenshots, false, persistent: true)
Application.put_env(:phoenix, :serve_endpoints, false, persistent: true)
{:ok, _} = Application.ensure_all_started(:vutuv)

import Ecto.Query
alias Vutuv.{Accounts, Repo}
alias Vutuv.References.JobReference

email = "friedhelm.poettering@example.com"

unless Accounts.get_user_by_handle_or_email(email) do
  conn = Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("accept-language", "de")

  {:ok, u} =
    Accounts.register_user(conn, %{
      "first_name" => "Friedhelm",
      "last_name" => "Pöttering",
      "emails" => %{"0" => %{"value" => email}},
      "tag_list" => "Lagerlogistik, Inventur, Führung"
    })

  IO.puts("SEED created @#{u.username}")
end

friedhelm = Accounts.get_user_by_handle_or_email(email)

Repo.query!(
  ~s|update users set "email_confirmed?" = true, locale = 'de', inserted_at = least(inserted_at, now() - interval '60 days') where id = $1|,
  [Ecto.UUID.dump!(friedhelm.id)]
)

# a clean slate: no reference, so no check either (they go with it)
for r <- Repo.all(from(r in JobReference, where: r.user_id == ^friedhelm.id)),
    do: Vutuv.References.delete_job_reference(r)

IO.puts("SEED ready @#{friedhelm.username} id=#{friedhelm.id}")
