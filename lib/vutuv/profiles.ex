defmodule Vutuv.Profiles do
  @moduledoc """
  The Profiles context. Handles addresses, phone numbers,
  social media accounts, URLs, and work experiences.
  """

  import Ecto.Query

  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo

  # ── Generic CRUD helpers ──

  def count_user_assoc(user, assoc_name) do
    user
    |> Ecto.assoc(assoc_name)
    |> select([a], count(a.id))
    |> Repo.one()
  end

  # ── Addresses ──

  def list_addresses(user), do: Repo.all(Ecto.assoc(user, :addresses))
  def get_address!(id), do: Repo.get!(Address, id)

  def create_address(user, attrs) do
    user |> Ecto.build_assoc(:addresses) |> Address.changeset(attrs) |> Repo.insert()
  end

  def update_address(%Address{} = address, attrs) do
    address |> Address.changeset(attrs) |> Repo.update()
  end

  def delete_address!(%Address{} = address), do: Repo.delete!(address)

  # ── Phone Numbers ──

  def list_phone_numbers(user), do: Repo.all(Ecto.assoc(user, :phone_numbers))
  def get_phone_number!(id), do: Repo.get!(PhoneNumber, id)

  def create_phone_number(user, attrs) do
    user |> Ecto.build_assoc(:phone_numbers) |> PhoneNumber.changeset(attrs) |> Repo.insert()
  end

  def update_phone_number(%PhoneNumber{} = phone_number, attrs) do
    phone_number |> PhoneNumber.changeset(attrs) |> Repo.update()
  end

  def delete_phone_number!(%PhoneNumber{} = phone_number), do: Repo.delete!(phone_number)

  # ── Social Media Accounts ──

  def list_social_media_accounts(user), do: Repo.all(Ecto.assoc(user, :social_media_accounts))
  def get_social_media_account!(id), do: Repo.get!(SocialMediaAccount, id)

  def create_social_media_account(user, attrs) do
    user
    |> Ecto.build_assoc(:social_media_accounts)
    |> SocialMediaAccount.changeset(attrs)
    |> Repo.insert()
  end

  def update_social_media_account(%SocialMediaAccount{} = account, attrs) do
    account |> SocialMediaAccount.changeset(attrs) |> Repo.update()
  end

  def delete_social_media_account!(%SocialMediaAccount{} = account), do: Repo.delete!(account)

  # ── URLs ──

  def list_urls(user), do: Repo.all(Ecto.assoc(user, :urls))
  def get_url!(id), do: Repo.get!(Url, id)

  def create_url(user, attrs) do
    user |> Ecto.build_assoc(:urls) |> Url.changeset(attrs) |> Repo.insert()
  end

  def update_url(%Url{} = url, attrs) do
    url |> Url.changeset(attrs) |> Repo.update()
  end

  def delete_url!(%Url{} = url), do: Repo.delete!(url)

  # ── Work Experiences ──

  def list_work_experiences(user) do
    user
    |> Ecto.assoc(:work_experiences)
    |> WorkExperience.order_by_date()
    |> Repo.all()
  end

  def get_work_experience!(id), do: Repo.get!(WorkExperience, id)

  def create_work_experience(user, attrs) do
    user
    |> Ecto.build_assoc(:work_experiences)
    |> WorkExperience.changeset(attrs)
    |> Repo.insert()
  end

  def update_work_experience(%WorkExperience{} = we, attrs) do
    we |> WorkExperience.changeset(attrs) |> Repo.update()
  end

  def delete_work_experience!(%WorkExperience{} = we), do: Repo.delete!(we)
end
