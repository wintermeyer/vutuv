defmodule Vutuv.Accounts.User do
  @moduledoc false

  use VutuvWeb, :model
  @derive {Phoenix.Param, key: :active_slug}

  schema "users" do
    field(:first_name, :string)
    field(:last_name, :string)
    field(:middlename, :string)
    field(:nickname, :string)
    field(:honorific_prefix, :string)
    field(:honorific_suffix, :string)
    field(:gender, :string)
    field(:birthdate, :date)
    field(:locale, :string)
    field(:verified, :boolean, default: false)
    field(:avatar, :string)
    field(:active_slug, :string)
    field(:administrator, :boolean)
    field(:headline, :string)
    field(:noindex?, :boolean, default: false)
    field(:validated?, :boolean, default: false)
    field(:send_birthday_reminder, :boolean, default: true)
    # Set programmatically by Vutuv.Activity.mark_notifications_read/1; never cast.
    field(:notifications_read_at, :naive_datetime)
    field(:easy_tags, :string, virtual: true)

    has_many(:search_query_requesters, Vutuv.Search.SearchQueryRequester)
    has_many(:search_query_results, Vutuv.Search.SearchQueryResult)
    has_many(:oauth_providers, Vutuv.Accounts.OAuthProvider)
    has_many(:login_pins, Vutuv.Accounts.LoginPin)
    has_many(:groups, Vutuv.Social.Group)
    has_many(:emails, Vutuv.Accounts.Email)
    has_many(:user_tags, Vutuv.Tags.UserTag)
    has_many(:user_skills, Vutuv.Profiles.UserSkill)
    has_many(:slugs, Vutuv.Accounts.Slug, on_replace: :nilify)
    has_many(:urls, Vutuv.Profiles.Url)
    has_many(:phone_numbers, Vutuv.Profiles.PhoneNumber)
    has_many(:addresses, Vutuv.Profiles.Address)
    has_many(:work_experiences, Vutuv.Profiles.WorkExperience)
    has_many(:social_media_accounts, Vutuv.Profiles.SocialMediaAccount)
    has_many(:search_terms, Vutuv.Accounts.SearchTerm, on_replace: :delete)
    has_many(:endorsements, Vutuv.Tags.UserTagEndorsement)
    has_many(:skill_endorsements, Vutuv.Profiles.Endorsement)
    has_many(:job_postings, Vutuv.JobPostings.JobPosting)
    has_many(:recruiter_subscriptions, Vutuv.Recruiting.RecruiterSubscription)
    has_many(:coupons, Vutuv.Recruiting.Coupon)

    has_many(:tags, through: [:user_tags, :tag])

    has_many(:follower_connections, Vutuv.Social.Connection, foreign_key: :followee_id)
    has_many(:followers, through: [:follower_connections, :follower])

    has_many(:followee_connections, Vutuv.Social.Connection, foreign_key: :follower_id)
    has_many(:followees, through: [:followee_connections, :followee])

    timestamps()
  end

  @optional_fields ~w(validated? noindex? headline first_name last_name middlename nickname honorific_prefix honorific_suffix gender birthdate locale active_slug send_birthday_reminder easy_tags)a

  @max_image_filesize Application.compile_env!(:vutuv, [VutuvWeb.Endpoint, :max_image_filesize])

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @optional_fields)
    |> validate_avatar(params)
    |> cast_assoc(:emails)
    |> cast_assoc(:slugs)
    |> cast_assoc(:oauth_providers)
    |> validate_first_name_or_last_name_or_nickname(params)
    |> validate_length(:first_name, max: 50)
    |> validate_length(:last_name, max: 50)
    |> validate_length(:middlename, max: 50)
    |> validate_length(:nickname, max: 50)
    |> validate_length(:honorific_prefix, max: 50)
    |> validate_length(:honorific_suffix, max: 50)
    |> validate_length(:gender, max: 50)
    |> validate_length(:headline, max: 255)
    |> nullify_default_birthdate()
    |> downcase_value()
  end

  defp validate_avatar(changeset, %{avatar: avatar}),
    do: validate_avatar(changeset, %{"avatar" => avatar})

  defp validate_avatar(changeset, %{"avatar" => avatar} = params) do
    stat = File.stat!(avatar.path)

    if stat.size > @max_image_filesize do
      add_error(
        changeset,
        :avatar,
        "Avatar filesize is greater than 2MB. Please upload a smaller image."
      )
    else
      cast_avatar_attachment(changeset, params)
    end
  end

  defp validate_avatar(changeset, %{}), do: changeset

  # The scope passed to the uploader must reflect any name/id changes in this
  # same changeset, because the on-disk file name is derived from it. This
  # mirrors what Waffle's `cast_attachments/3` did via `apply_changes/1`.
  defp cast_avatar_attachment(changeset, %{"avatar" => %Plug.Upload{} = upload}) do
    case Vutuv.Avatar.store({upload, Ecto.Changeset.apply_changes(changeset)}) do
      {:ok, file_name} -> put_change(changeset, :avatar, file_name)
      {:error, _reason} -> add_error(changeset, :avatar, "is not a valid image")
    end
  end

  defp cast_avatar_attachment(changeset, _params), do: changeset

  defp validate_first_name_or_last_name_or_nickname(changeset, %{}) do
    first_name = get_field(changeset, :first_name)
    last_name = get_field(changeset, :last_name)
    nickname = get_field(changeset, :nickname)

    if first_name || last_name || nickname do
      changeset
    else
      message = "First name or last name or nickname must be present"

      changeset
      |> add_error(:first_name, message)
      |> add_error(:last_name, message)
      |> add_error(:nickname, message)
    end
  end

  def gender_gettext("male"), do: Gettext.gettext(VutuvWeb.Gettext, "Male")
  def gender_gettext("female"), do: Gettext.gettext(VutuvWeb.Gettext, "Female")
  def gender_gettext(_), do: Gettext.gettext(VutuvWeb.Gettext, "Other")

  defp downcase_value(changeset) do
    update_change(changeset, :active_slug, &String.downcase/1)
  end

  defp nullify_default_birthdate(changeset) do
    case get_field(changeset, :birthdate) do
      ~D[1900-01-01] -> put_change(changeset, :birthdate, nil)
      _ -> changeset
    end
  end

  defimpl String.Chars, for: Vutuv.Accounts.User do
    def to_string(user), do: "#{user.first_name} #{user.last_name}"
  end

  defimpl List.Chars, for: Vutuv.Accounts.User do
    def to_charlist(user), do: ~c"#{user.first_name} #{user.last_name}"
  end
end
