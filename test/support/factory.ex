defmodule Vutuv.Factory do
  @moduledoc false

  use ExMachina.Ecto, repo: Vutuv.Repo

  alias Vutuv.Jobs.JobPostingImage
  alias Vutuv.Posts.PostImage

  def user_factory do
    %Vutuv.Accounts.User{
      first_name: sequence(:first_name, &"User#{&1}"),
      last_name: "Test",
      username: sequence(:username, &"user-#{&1}"),
      locale: "en"
    }
  end

  def activated_user_factory do
    struct!(user_factory(), email_confirmed?: true)
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

  # One entry on a member's job-search viewer-exclusion list (issue #938).
  # Pass either `excluded_user:` (a member) or `domain:` (a lowercase host);
  # never both. Defaults to a domain row so a bare `insert(:viewer_exclusion,
  # user: owner)` is valid against the one-target check constraint.
  def viewer_exclusion_factory do
    %Vutuv.Accounts.ViewerExclusion{
      domain: sequence(:excluded_domain, &"employer-#{&1}.example")
    }
  end

  # One row per username change: the ledger behind the 4-per-90-days quota.
  def username_change_factory do
    %Vutuv.Accounts.UsernameChange{
      value: sequence(:username_change_value, &"old_handle_#{&1}")
    }
  end

  # One enrolled passkey (issue #795). The crypto round-trip can only be
  # exercised by a real browser, so this stands in for a verified credential:
  # a unique credential_id and a minimal serialized COSE key, the shape
  # Vutuv.Credentials persists after Wax.register/3.
  def user_credential_factory do
    cose_key = %{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => :crypto.strong_rand_bytes(32),
      -3 => :crypto.strong_rand_bytes(32)
    }

    %Vutuv.Credentials.UserCredential{
      user: build(:activated_user),
      credential_id: sequence(:credential_id, &:crypto.hash(:sha256, "credential-#{&1}")),
      public_key: :erlang.term_to_binary(cose_key),
      sign_count: 0,
      nickname: sequence(:passkey_nickname, &"Passkey #{&1}")
    }
  end

  @doc """
  Inserts an activated user. Resolution is by `users.username` alone, so
  nothing else is needed for slug-routed pages.
  """
  def insert_activated_user(attrs \\ []) do
    insert(:activated_user, attrs)
  end

  # A booked text ad (Vutuv.Ads), approved by default so it serves; pass
  # `approved_at: nil` for one still waiting for the admin review. Day
  # defaults to the first bookable day; banner tests override it with
  # `day: Vutuv.Ads.today()`.
  def ad_factory do
    %Vutuv.Ads.Ad{
      day: Vutuv.Ads.first_bookable_day(),
      approved_at: DateTime.truncate(DateTime.utc_now(), :second),
      content: sequence(:ad_content, &"**Ad #{&1}** content"),
      price_cents: Vutuv.Ads.price_cents(),
      billing_name: sequence(:billing_name, &"Billing Name #{&1}"),
      billing_street: "Musterstraße 1",
      billing_zip_code: "10115",
      billing_city: "Berlin",
      billing_country: "Deutschland"
    }
  end

  def oauth_app_factory do
    %Vutuv.ApiAuth.App{
      user: build(:activated_user),
      name: sequence(:oauth_app_name, &"App #{&1}"),
      client_id: sequence(:oauth_client_id, &"vutuv_app_test_#{&1}"),
      redirect_uris: ["https://example.org/callback"]
    }
  end

  def api_token_factory do
    %Vutuv.ApiAuth.Token{
      kind: "pat",
      name: sequence(:api_token_name, &"Token #{&1}"),
      scopes: ["profile:read"],
      token_hash: sequence(:api_token_hash, &Vutuv.ApiAuth.hash_token("factory_token_#{&1}"))
    }
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
      minted_at: NaiveDateTime.utc_now(),
      pin_hash:
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
      number_type: "Cell"
    }
  end

  def social_media_account_factory do
    %Vutuv.Profiles.SocialMediaAccount{
      provider: "GitHub",
      value: sequence(:social_value, &"user#{&1}")
    }
  end

  def messenger_factory do
    %Vutuv.Profiles.Messenger{
      provider: "Telegram",
      value: sequence(:messenger_value, &"user#{&1}")
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

  # A verified organization page (issue #929). Defaults to `active` + `verified_at`
  # so `insert(:organization)` is immediately a linkable target (issue #931);
  # override `status:`/`frozen_at:` for the pending/frozen cases.
  def organization_factory do
    %Vutuv.Organizations.Organization{
      name: sequence(:organization_name, &"Organization #{&1}"),
      slug: sequence(:organization_slug, &"organization-#{&1}"),
      kind: :company,
      city: "Berlin",
      country: "DE",
      status: "active",
      verified_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    }
  end

  def education_factory do
    %Vutuv.Profiles.Education{
      school: "Acme University",
      degree: "BSc Computer Science",
      field_of_study: "Computer Science",
      description: "Studied things",
      start_year: 2010,
      end_year: 2014,
      slug: sequence(:education_slug, &"bsc-acme-#{&1}")
    }
  end

  def language_factory do
    %Vutuv.Profiles.Language{
      language_code: sequence(:language_code, ~w(en de fr es it)),
      proficiency: "b2"
    }
  end

  def qualification_factory do
    %Vutuv.Profiles.Qualification{
      name: sequence(:qualification_name, &"AWS Solutions Architect #{&1}"),
      kind: "certification",
      issuer: "Amazon Web Services",
      awarded_year: 2023
    }
  end

  def follow_factory do
    %Vutuv.Social.Follow{}
  end

  @doc """
  Inserts a bare `Follow` row (a one-directional follow edge) without the
  notification side effects of `Social.follow/2`.
  """
  def follow!(follower, followee) do
    insert(:follow, follower: follower, followee: followee)
  end

  @doc """
  Makes two users **vernetzt** (connected) by inserting both follow edges,
  without the notification side effects of `Social.follow/2`. Vernetzt is a
  mutual follow now — there is no separate connection record. The optional
  third argument (the old requester) is accepted and ignored for call-site
  compatibility. Returns `:ok`.
  """
  def connect!(a, b, _requested_by \\ nil) do
    follow!(a, b)
    follow!(b, a)
    :ok
  end

  def tag_factory do
    %Vutuv.Tags.Tag{
      name: sequence(:tag_name, &"Tag Name #{&1}"),
      slug: sequence(:tag_slug, &"tag-#{&1}")
    }
  end

  @doc """
  A per-call unique tag name with a readable base ("Elixir-123").

  Async test modules must never insert the same tag name as another module:
  under the SQL sandbox every minted slug keeps its unique-index lock until
  the test transaction rolls back, so shared names convoy and deadlock
  (the 40P01 register_user flake). Use this wherever a test types a tag
  value into a flow (add_user_tag, tag forms, post tags) and the exact
  spelling is not the point — bind it to a variable and assert on that.
  """
  def unique_tag_name(base \\ "tag"), do: "#{base}-#{System.unique_integer([:positive])}"

  def user_tag_factory do
    %Vutuv.Tags.UserTag{}
  end

  def saved_search_factory do
    %Vutuv.SavedSearches.SavedSearch{
      user: build(:activated_user),
      kind: :jobs,
      query: "q=elixir",
      notify: :daily
    }
  end

  def user_tag_endorsement_factory do
    %Vutuv.Tags.UserTagEndorsement{}
  end

  def tag_follow_factory do
    %Vutuv.Tags.TagFollow{}
  end

  def post_factory do
    %Vutuv.Posts.Post{
      body: sequence(:post_body, &"Post body #{&1}"),
      published_on: Vutuv.BerlinTime.today(),
      user: build(:user)
    }
  end

  def post_reply_factory do
    %Vutuv.Posts.PostReply{
      post: build(:post),
      parent_post: build(:post),
      parent_author: build(:user)
    }
  end

  def post_image_factory do
    %Vutuv.Posts.PostImage{
      token: PostImage.gen_token(),
      alt: "",
      position: 0,
      width: 800,
      height: 600,
      content_type: "image/jpeg",
      size_bytes: 123_456,
      # Tests run with :moderate_images off, where a stored image is born
      # released; the schema/DB default is the fail-closed "pending". The
      # moderation tests set "pending" through the real upload chokepoints.
      moderation: "approved",
      user: build(:user)
    }
  end

  def job_posting_image_factory do
    %JobPostingImage{
      token: JobPostingImage.gen_token(),
      alt: "",
      position: 0,
      width: 800,
      height: 600,
      content_type: "image/jpeg",
      size_bytes: 123_456,
      # See post_image_factory: released, like every flag-off store.
      moderation: "approved",
      user: build(:user)
    }
  end

  def strike_factory do
    %Vutuv.Moderation.Strike{
      role: "owner",
      level: 1,
      expires_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 365 * 86_400)
    }
  end

  def conversation_factory do
    %Vutuv.Chat.Conversation{}
  end

  def conversation_participant_factory do
    %Vutuv.Chat.Participant{}
  end

  def message_factory do
    %Vutuv.Chat.Message{
      body: sequence(:message_body, &"Message body #{&1}")
    }
  end

  def email_bounce_factory do
    %Vutuv.Notifications.EmailBounce{
      email_value: sequence(:bounce_value, &"dead#{&1}@example.com"),
      action: "failed",
      status: "5.1.1",
      raw: "550 5.1.1 User unknown"
    }
  end

  def deliverability_event_factory do
    %Vutuv.Deliverability.Event{
      action: "account_frozen",
      detail: %{}
    }
  end

  @doc """
  Inserts a conversation between the two users with both participant rows,
  taking care of the sorted-pair invariant. `initiator` defaults to `a`.
  """
  def insert_conversation_between(a, b, attrs \\ []) do
    {status, attrs} = Keyword.pop(attrs, :status, "accepted")
    {initiator, attrs} = Keyword.pop(attrs, :initiator, a)
    {user_a, user_b} = if a.id < b.id, do: {a, b}, else: {b, a}

    conversation =
      insert(
        :conversation,
        Keyword.merge(
          [user_a: user_a, user_b: user_b, initiator: initiator, status: status],
          attrs
        )
      )

    insert(:conversation_participant, conversation: conversation, user: a)
    insert(:conversation_participant, conversation: conversation, user: b)
    conversation
  end
end
