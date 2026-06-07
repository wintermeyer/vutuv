defmodule Vutuv.Factory do
  @moduledoc false

  use ExMachina.Ecto, repo: Vutuv.Repo

  def user_factory do
    %Vutuv.Accounts.User{
      first_name: sequence(:first_name, &"User#{&1}"),
      last_name: "Test",
      active_slug: sequence(:active_slug, &"user-#{&1}"),
      locale: "en"
    }
  end

  def email_factory do
    %Vutuv.Accounts.Email{
      value: sequence(:email_value, &"user#{&1}@example.com"),
      public?: true,
      md5sum:
        sequence(
          :md5sum,
          &(:crypto.hash(:md5, "user#{&1}@example.com") |> Base.encode16() |> String.downcase())
        )
    }
  end

  def slug_factory do
    %Vutuv.Accounts.Slug{
      value: sequence(:slug_value, &"user-slug-#{&1}")
    }
  end

  @doc """
  Inserts a validated user plus the enabled `Slug` row matching `active_slug` —
  the shape every slug-routed page needs to resolve the user.
  """
  def insert_validated_user(attrs \\ []) do
    user = insert(:user, Keyword.merge([validated?: true], attrs))
    insert(:slug, value: user.active_slug, disabled: false, user: user)
    user
  end

  def search_term_factory do
    %Vutuv.Accounts.SearchTerm{
      value: sequence(:search_term_value, &"term-#{&1}"),
      score: 100
    }
  end

  def login_pin_factory do
    %Vutuv.Accounts.LoginPin{
      type: "login",
      created_at: NaiveDateTime.utc_now(),
      pin:
        sequence(:login_pin_hash, &Base.encode16(:crypto.hash(:sha256, "#{&1}"), case: :lower)),
      pin_salt: :crypto.strong_rand_bytes(16),
      pin_login_attempts: 0
    }
  end

  def address_factory do
    %Vutuv.Profiles.Address{
      description: "Home",
      country: "Germany",
      city: "Berlin",
      zip_code: "10115"
    }
  end

  def phone_number_factory do
    %Vutuv.Profiles.PhoneNumber{
      value: sequence(:phone_value, &"+49 30 #{&1}00000"),
      number_type: "mobile"
    }
  end

  def social_media_account_factory do
    %Vutuv.Profiles.SocialMediaAccount{
      provider: "GitHub",
      value: sequence(:social_value, &"user#{&1}")
    }
  end

  def url_factory do
    %Vutuv.Profiles.Url{
      value: "http://example.org/",
      description: "Test Url"
    }
  end

  def work_experience_factory do
    %Vutuv.Profiles.WorkExperience{
      title: "Developer",
      organization: "Acme Corp",
      description: "Building things",
      start_month: 1,
      start_year: 2020,
      slug: sequence(:work_slug, &"developer-acme-#{&1}")
    }
  end

  def connection_factory do
    %Vutuv.Social.Connection{}
  end

  def group_factory do
    %Vutuv.Social.Group{
      name: sequence(:group_name, &"Group #{&1}")
    }
  end

  def membership_factory do
    %Vutuv.Social.Membership{}
  end

  def tag_factory do
    %Vutuv.Tags.Tag{
      name: sequence(:tag_name, &"Tag Name #{&1}"),
      slug: sequence(:tag_slug, &"tag-#{&1}")
    }
  end

  def user_tag_factory do
    %Vutuv.Tags.UserTag{}
  end

  def user_tag_endorsement_factory do
    %Vutuv.Tags.UserTagEndorsement{}
  end

  def post_factory do
    %Vutuv.Posts.Post{
      body: sequence(:post_body, &"Post body #{&1}"),
      published_on: Date.utc_today(),
      # Globally unique, so explicit factory posts never collide on the
      # (user_id, published_on, seq) index. Context-created posts count from 1.
      seq: sequence(:post_seq, &(&1 + 1_000)),
      user: build(:user)
    }
  end

  def post_image_factory do
    %Vutuv.Posts.PostImage{
      token: Vutuv.Posts.PostImage.gen_token(),
      alt: "",
      position: 0,
      width: 800,
      height: 600,
      content_type: "image/jpeg",
      size_bytes: 123_456,
      user: build(:user)
    }
  end

  def o_auth_provider_factory do
    %Vutuv.Accounts.OAuthProvider{
      provider: "google",
      provider_id: sequence(:provider_id, &"google-id-#{&1}")
    }
  end
end
