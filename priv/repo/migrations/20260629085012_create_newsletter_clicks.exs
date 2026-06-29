defmodule Vutuv.Repo.Migrations.CreateNewsletterClicks do
  use Ecto.Migration

  def change do
    # One row per click on a vutuv.de link carried in a newsletter: who clicked
    # which link when. Newsletter HTML mail rewrites every internal link so its
    # href carries a signed per-recipient token (?nlt=...); when the recipient
    # follows it, VutuvWeb.Plug.NewsletterClick records the click here and
    # redirects to the clean URL. The plain-text body keeps the bare link, so
    # this only ever captures HTML clicks.
    #
    # url is the path that was clicked (the tracking param stripped), so the
    # admin can see which link drew the clicks. user_id nilifies if the member
    # is later deleted, like newsletter_deliveries, so the aggregate success
    # numbers survive an account deletion. A plain new table -> backward
    # compatible in one deploy.
    create table(:newsletter_clicks) do
      add(:newsletter_id, references(:newsletters, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :nilify_all))
      add(:url, :string, null: false)
      timestamps(updated_at: false)
    end

    # The success overview groups a newsletter's clicks by link and by member,
    # and the detail log lists them newest first.
    create(index(:newsletter_clicks, [:newsletter_id, :inserted_at]))
    create(index(:newsletter_clicks, [:newsletter_id, :user_id]))
  end
end
