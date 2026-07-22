defmodule Vutuv.Release do
  @moduledoc """
  Release tasks for an assembled `mix release`, where Mix is not available.

  Run migrations during deploy with:

      bin/vutuv eval "Vutuv.Release.migrate()"
  """
  alias Vutuv.Posts.ReviewCovers
  alias Vutuv.Uploads.LegacyRelabel
  alias Vutuv.Uploads.LegacySweeper
  alias Vutuv.Uploads.Regenerator

  @app :vutuv

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Grants admin rights to the member behind a username or email address — how a
  production installation mints its (first) admin (`Vutuv.Accounts.promote_admin/1`;
  the flag is never settable through a form or the API):

      bin/vutuv eval 'Vutuv.Release.promote_admin("stefan.wintermeyer")'
  """
  def promote_admin(identifier) when is_binary(identifier) do
    load_app()
    [repo] = repos()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn _repo ->
        case Vutuv.Accounts.promote_admin(identifier) do
          {:ok, user} ->
            IO.puts("@#{user.username} is an admin now.")

          {:error, :not_found} ->
            IO.puts(
              "No member found for #{inspect(identifier)} (looked up as @handle and email)."
            )

          {:error, changeset} ->
            IO.puts("Could not promote #{inspect(identifier)}: #{inspect(changeset.errors)}")
        end
      end)

    :ok
  end

  @doc """
  Re-derives every served image version from the private originals per the
  current `Vutuv.Uploads.Spec` (see `Vutuv.Uploads.Regenerator`). Safe to run
  while the app serves traffic (only the repo is started — no port binding):

      bin/vutuv eval "Vutuv.Release.regenerate_images()"
      bin/vutuv eval "Vutuv.Release.regenerate_images(dry_run: true)"
      bin/vutuv eval "Vutuv.Release.regenerate_images(only: :avatars)"
  """
  def regenerate_images(opts \\ []) do
    load_app()
    {:ok, _} = Application.ensure_all_started(:image)

    [repo] = repos()

    {:ok, summary, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> Regenerator.run(opts) end)

    summary
  end

  @doc """
  Re-fetches every book review's cover from Open Library at the current
  `Vutuv.Uploads.Spec` size and purges the private originals kept before
  v7.122.4. Covers are the one image kind with no local original to re-derive
  from (`Vutuv.ReviewCover`), so this is their `regenerate_images/1`. It
  paces itself (3s between fetches by default) to stay inside Open Library's
  rate limit; needs outbound network and `:fetch_book_metadata` on:

      bin/vutuv eval "Vutuv.Release.refresh_review_covers()"
      bin/vutuv eval "Vutuv.Release.refresh_review_covers(delay: 5_000)"
  """
  def refresh_review_covers(opts \\ []) do
    load_app()
    {:ok, _} = Application.ensure_all_started(:image)
    {:ok, _} = Application.ensure_all_started(:req)

    [repo] = repos()

    {:ok, summary, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> ReviewCovers.refresh_all(opts) end)

    summary
  end

  @doc """
  Deletes the legacy avatar/cover files the regenerator kept during the expand
  phase — the **contract** step of the fingerprint migration (see
  `Vutuv.Uploads.LegacySweeper`). Run this **only once** the fingerprinted
  scheme is confirmed healthy in production; it is never part of the deploy:

      bin/vutuv eval "Vutuv.Release.sweep_legacy_images(dry_run: true)"
      bin/vutuv eval "Vutuv.Release.sweep_legacy_images()"
  """
  def sweep_legacy_images(opts \\ []) do
    load_app()

    [repo] = repos()

    {:ok, summary, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> LegacySweeper.run(opts) end)

    summary
  end

  @doc """
  Renames the on-disk image directories from their legacy integer id to the new
  UUID after the `convert_ids_to_uuid_v7` migration, using the `legacy_id_map`
  table that migration leaves behind (see `Vutuv.Uploads.LegacyRelabel`). Run
  this **once, before `regenerate_images/1`**, on the UUID cutover deploy:

      bin/vutuv eval "Vutuv.Release.relabel_image_dirs()"
      bin/vutuv eval "Vutuv.Release.relabel_image_dirs(dry_run: true)"

  Returns `{:ok, summary}` or `{:error, :no_mapping}` (table absent/empty).
  """
  def relabel_image_dirs(opts \\ []) do
    load_app()

    [repo] = repos()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> LegacyRelabel.run(opts) end)

    result
  end

  @doc """
  Restores the invitation "invite once, site-wide" dedup guard after the issue
  #942 SHA-256 → HMAC cutover. Reads a newline-separated file of **plaintext**
  email addresses (one per line, blanks ignored) and inserts one dedup-only
  invitation row per distinct normalized (trimmed + downcased) address, hashed
  with the current keyed `Vutuv.Invitations.hash_email/1` — using this node's
  own `secret_key_base`, so no secret ever leaves the box. The rows are owned by
  `inviter` (a member handle or email, resolved like `promote_admin/1`); they
  carry no recovered metadata. Already-present addresses are no-ops.

      bin/vutuv eval 'Vutuv.Release.reseed_invitations("/var/www/vutuv3/shared/invited_emails.txt", "stefan.wintermeyer")'

  The plaintext file is never committed to git and should be deleted from the
  server once this has run. Prints and returns a `%{inserted:, total:}` summary
  (or `{:error, :inviter_not_found}`).
  """
  def reseed_invitations(path, inviter_identifier)
      when is_binary(path) and is_binary(inviter_identifier) do
    load_app()
    [repo] = repos()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo ->
        emails = path |> File.read!() |> String.split(["\r\n", "\n"], trim: true)

        case Vutuv.Accounts.get_user_by_handle_or_email(inviter_identifier) do
          nil ->
            {:error, :inviter_not_found}

          inviter ->
            Vutuv.Invitations.reseed_dedup(emails, inviter)
        end
      end)

    case result do
      {:error, :inviter_not_found} ->
        IO.puts("reseed_invitations: no member found for #{inspect(inviter_identifier)}.")

      %{inserted: inserted, total: total} ->
        IO.puts(
          "reseed_invitations: #{inserted} inserted, #{total - inserted} already present (#{total} distinct addresses)."
        )
    end

    result
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
