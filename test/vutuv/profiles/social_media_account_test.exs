defmodule Vutuv.Profiles.SocialMediaAccountTest do
  use Vutuv.DataCase, async: true

  import Phoenix.HTML, only: [safe_to_string: 1]

  alias Vutuv.Profiles.SocialMediaAccount

  defp value_for(params) do
    SocialMediaAccount.changeset(%SocialMediaAccount{}, params)
    |> Ecto.Changeset.apply_changes()
    |> Map.get(:value)
  end

  describe "changeset/2 provider validation" do
    test "accepts a supported provider" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Facebook",
          value: "vutuv"
        })

      assert changeset.valid?
    end

    test "accepts each provider that carries its own instance, and Bluesky" do
      for {provider, value} <- [
            {"Mastodon", "@Gargron@mastodon.social"},
            {"Pixelfed", "@dansup@pixelfed.social"},
            {"Bluesky", "gargron.bsky.social"}
          ] do
        changeset =
          SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
            provider: provider,
            value: value
          })

        assert changeset.valid?, "expected #{provider} to accept #{value}"
      end
    end

    test "accepts the code forges GitHub, GitLab and Codeberg (#921)" do
      for provider <- ~w(GitHub GitLab Codeberg) do
        changeset =
          SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
            provider: provider,
            value: "wintermeyer"
          })

        assert changeset.valid?, "expected #{provider} to be an accepted provider"
      end
    end

    test "rejects Google+ as a provider" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: "Google+", value: "vutuv"})

      refute changeset.valid?
      assert changeset.errors[:provider]
    end

    test "rejects a federated handle without an instance, naming the brand" do
      for {provider, value, example} <- [
            {"Mastodon", "Gargron", "instance.social"},
            {"Pixelfed", "dansup", "pixelfed.social"}
          ] do
        changeset =
          SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
            provider: provider,
            value: value
          })

        refute changeset.valid?, "expected #{provider} to refuse a bare #{value}"
        assert Enum.any?(errors_on(changeset).value, &(&1 =~ example))
      end
    end

    test "rejects a Mastodon-style handle for Bluesky" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Bluesky",
          value: "alice@example.social"
        })

      refute changeset.valid?
      assert changeset.errors[:value]
    end
  end

  # Other networks allow characters vutuv's own username never will. LinkedIn
  # slugs, for one, carry German umlauts (sebastian-hädrich) — so the generic
  # handle validation must accept anything non-blank, not just [A-Za-z0-9._-].
  # See issue #854 (follow-up of #748).
  describe "changeset/2 non-ASCII handles for regular providers (#854)" do
    test "accepts a LinkedIn handle containing German umlauts" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "LinkedIn",
          value: "sebastian-hädrich"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :value) == "sebastian-hädrich"
    end

    test "extracts an umlaut handle from a pasted LinkedIn profile URL" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "LinkedIn",
          value: "https://www.linkedin.com/in/sebastian-hädrich/"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :value) == "sebastian-hädrich"
    end

    test "accepts a percent-encoded umlaut handle from a pasted LinkedIn URL" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "LinkedIn",
          value: "https://www.linkedin.com/in/sebastian-h%C3%A4drich/"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :value) == "sebastian-h%C3%A4drich"
    end

    test "still rejects a blank handle after normalization" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{provider: "LinkedIn", value: "old"}, %{
          value: "   "
        })

      refute changeset.valid?
      assert changeset.errors[:value]
    end
  end

  describe "Bluesky value parsing" do
    test "stores the handle lowercased, stripping a leading @" do
      assert value_for(%{provider: "Bluesky", value: "@Alice.Bsky.Social"}) ==
               "alice.bsky.social"
    end

    test "a bare name without a dot gets the default .bsky.social namespace" do
      assert value_for(%{provider: "Bluesky", value: "alice"}) == "alice.bsky.social"
    end

    test "a custom-domain handle is stored as typed" do
      assert value_for(%{provider: "Bluesky", value: "alice.example.com"}) ==
               "alice.example.com"
    end

    test "extracts the handle from a pasted profile URL" do
      assert value_for(%{
               provider: "Bluesky",
               value: "https://bsky.app/profile/alice.bsky.social"
             }) ==
               "alice.bsky.social"
    end

    test "rejects a handle that overflows varchar(255) only after normalization" do
      # 250 chars fits the column, but ".bsky.social" is appended AFTER, so the
      # length must be validated on the normalized value (else Postgres 22001).
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Bluesky",
          value: String.duplicate("a", 250)
        })

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).value, &(&1 =~ "at most"))
    end
  end

  # Mastodon and Pixelfed share one parser: the instance is part of the handle
  # for both, and only the path their instance serves a profile at differs
  # (Mastodon's /@user, Pixelfed's bare /user — pixelfed.social answers
  # /@dansup with a 302 to /dansup, which is why both paths must be accepted).
  describe "federated value parsing" do
    test "stores user@instance from every shape a member can paste" do
      for value <- [
            "@Gargron@mastodon.social",
            "Gargron@mastodon.social",
            "https://mastodon.social/@Gargron",
            "https://mastodon.social/Gargron"
          ] do
        assert value_for(%{provider: "Mastodon", value: value}) == "Gargron@mastodon.social",
               "expected #{value} to store Gargron@mastodon.social"
      end
    end

    test "reads a post URL and the ActivityPub /users/<name> id as their account" do
      for value <- [
            "https://mastodon.social/@Gargron/113000000000000000",
            "https://mastodon.social/users/Gargron"
          ] do
        assert value_for(%{provider: "Mastodon", value: value}) == "Gargron@mastodon.social",
               "expected #{value} to store Gargron@mastodon.social"
      end
    end

    # The parser used to take the first path word as the handle, so another
    # network's profile URL was stored as "profile@host" without a word.
    test "refuses a deeper path it cannot read instead of storing its first word" do
      for {provider, value} <- [
            {"Mastodon", "https://friendica.opensocial.space/profile/herku"},
            {"Pixelfed", "https://pixelfed.social/p/dansup/123"}
          ] do
        changeset =
          SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: provider, value: value})

        refute changeset.valid?, "expected #{value} to be refused for #{provider}"
      end
    end

    test "reads a bare /user path, which is the only form Pixelfed links" do
      assert value_for(%{provider: "Pixelfed", value: "https://pixelfed.social/dansup"}) ==
               "dansup@pixelfed.social"

      assert value_for(%{provider: "Pixelfed", value: "@dansup@pixelfed.social"}) ==
               "dansup@pixelfed.social"
    end

    # A host is case-insensitive, the (provider, value) unique index is not, so
    # a typed capital must not buy a second row for the same account.
    test "lowercases the instance, whether typed or pasted, keeping the localpart" do
      assert value_for(%{provider: "Pixelfed", value: "https://Pixelfed.Social/DanSup"}) ==
               "DanSup@pixelfed.social"

      assert value_for(%{provider: "Mastodon", value: "@Gargron@Mastodon.Social"}) ==
               "Gargron@mastodon.social"
    end

    test "drops a query or fragment a share sheet appended" do
      assert value_for(%{provider: "Pixelfed", value: "https://pixelfed.social/dansup?ref=x"}) ==
               "dansup@pixelfed.social"

      assert value_for(%{provider: "Mastodon", value: "https://mastodon.social/@Gargron#bio"}) ==
               "Gargron@mastodon.social"
    end

    # BookWyrm serves a profile at /user/<name>, so the generic parser would
    # read the path word "user" as the handle.
    test "reads BookWyrm's /user/<name> profile URL and the address form" do
      for value <- [
            "https://bookwyrm.de/user/Be_Kinky",
            "https://BookWyrm.de/user/Be_Kinky/?tab=reviews",
            "@Be_Kinky@bookwyrm.de",
            "Be_Kinky@bookwyrm.de"
          ] do
        assert value_for(%{provider: "BookWyrm", value: value}) == "Be_Kinky@bookwyrm.de",
               "expected #{value} to store Be_Kinky@bookwyrm.de"
      end
    end

    test "links a BookWyrm account at /user/<name> and shows the full address" do
      account = %SocialMediaAccount{provider: "BookWyrm", value: "Be_Kinky@bookwyrm.de"}

      assert SocialMediaAccount.url(account) == "https://bookwyrm.de/user/Be_Kinky"
      assert SocialMediaAccount.display(account) == "@Be_Kinky@bookwyrm.de"
    end

    # Friendica serves a profile at /profile/<name> (and /~<name>), so the
    # generic parser stored the path word as the handle: "profile@host".
    test "reads Friendica's /profile/<name> and /~<name> URLs and the address form" do
      for value <- [
            "https://friendica.opensocial.space/profile/herku",
            "https://Friendica.OpenSocial.space/profile/herku/?tab=posts",
            "https://friendica.opensocial.space/~herku",
            "@herku@friendica.opensocial.space",
            "herku@friendica.opensocial.space"
          ] do
        assert value_for(%{provider: "Friendica", value: value}) ==
                 "herku@friendica.opensocial.space",
               "expected #{value} to store herku@friendica.opensocial.space"
      end
    end

    test "links a Friendica account at /profile/<name>, where Friendica serves it" do
      account = %SocialMediaAccount{provider: "Friendica", value: "herku@friendica.example"}

      assert SocialMediaAccount.url(account) == "https://friendica.example/profile/herku"
      assert SocialMediaAccount.display(account) == "@herku@friendica.example"
    end

    test "rejects a Friendica name without its instance, naming the brand" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: "Friendica", value: "x"})

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).value, &(&1 =~ "friendica.example"))
    end

    # The federated brands' messages were missing from the errors catalog, so a
    # German member read them in English.
    test "the federated handle messages are translated into German" do
      for {provider, german} <- [
            {"Friendica", "Friendica-Handle"},
            {"Pixelfed", "Pixelfed-Handle"},
            {"BookWyrm", "BookWyrm-Handle"}
          ] do
        changeset =
          SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: provider, value: "x"})

        {message, _opts} = changeset.errors[:value]

        assert Gettext.with_locale(VutuvWeb.Gettext, "de", fn ->
                 Gettext.dgettext(VutuvWeb.Gettext, "errors", message)
               end) =~ "Geben Sie Ihr vollständiges #{german} an"
      end
    end

    test "rejects a BookWyrm name without its instance, naming the brand" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: "BookWyrm", value: "x"})

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).value, &(&1 =~ "bookwyrm.social"))
    end
  end

  describe "code-forge value parsing (#921)" do
    test "extracts the handle from a pasted GitLab profile URL" do
      assert value_for(%{provider: "GitLab", value: "https://gitlab.com/wintermeyer"}) ==
               "wintermeyer"
    end

    test "extracts the handle from a pasted Codeberg profile URL with trailing slash" do
      assert value_for(%{provider: "Codeberg", value: "https://codeberg.org/alice/"}) ==
               "alice"
    end

    test "strips a leading @ from a typed handle" do
      assert value_for(%{provider: "GitLab", value: "@wintermeyer"}) == "wintermeyer"
    end
  end

  # A code-forge profile is always host + a single-segment username
  # (gitlab.com/name). GitLab additionally serves a numeric-ID profile under its
  # reserved "-" namespace (gitlab.com/-/u/7984176) — a form the bare-handle
  # store cannot represent: parse_value/1 keeps only the last path segment
  # ("7984176") and url/1 rebuilds the wrong link (gitlab.com/7984176). Rather
  # than store a silently-broken link, reject any code-forge value whose path
  # carries more than the single username segment. See issue #923.
  describe "code-forge reserved / multi-segment paths (#923)" do
    test "rejects GitLab's numeric /-/u/ ID profile URL" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "GitLab",
          value: "https://gitlab.com/-/u/7984176"
        })

      refute changeset.valid?
      assert changeset.errors[:value]
    end

    test "rejects the bare -/u/<id> path a member might paste" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "GitLab",
          value: "-/u/7984176"
        })

      refute changeset.valid?
      assert changeset.errors[:value]
    end

    test "rejects a GitHub URL that carries a repository path" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "GitHub",
          value: "https://github.com/wintermeyer/vutuv"
        })

      refute changeset.valid?
      assert changeset.errors[:value]
    end

    test "still accepts a plain GitLab username" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "GitLab",
          value: "wintermeyer"
        })

      assert changeset.valid?
      assert value_for(%{provider: "GitLab", value: "wintermeyer"}) == "wintermeyer"
    end

    test "still accepts a pasted GitLab profile URL" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "GitLab",
          value: "https://gitlab.com/wintermeyer"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :value) == "wintermeyer"
    end

    test "still accepts a Codeberg profile URL with a trailing slash" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Codeberg",
          value: "https://codeberg.org/alice/"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :value) == "alice"
    end
  end

  # A self-hosted Gitea/Forgejo instance has no fixed host, so the value carries
  # its own (name@git.example.com) exactly as a Mastodon handle does. See issue
  # #1504; the instance itself is asked in Vutuv.CodeStats.verify_instance/1.
  describe "self-hosted forge value parsing (#1504)" do
    test "accepts Gitea and Forgejo as providers" do
      for provider <- ~w(Gitea Forgejo) do
        changeset =
          SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
            provider: provider,
            value: "hans@git.example.com"
          })

        assert changeset.valid?, "expected #{provider} to be an accepted provider"
      end
    end

    test "stores the address form as typed, host lowercased" do
      assert value_for(%{provider: "Forgejo", value: "Hans@Git.Example.COM"}) ==
               "Hans@git.example.com"
    end

    test "extracts the pair from a pasted profile URL" do
      assert value_for(%{provider: "Gitea", value: "https://git.example.com/hans"}) ==
               "hans@git.example.com"
    end

    test "takes a pasted URL with no scheme, a trailing slash and a query" do
      assert value_for(%{provider: "Gitea", value: "git.example.com/hans/?tab=activity"}) ==
               "hans@git.example.com"
    end

    test "strips a leading @ from the address form" do
      assert value_for(%{provider: "Forgejo", value: "@hans@git.example.com"}) ==
               "hans@git.example.com"
    end

    test "rejects a bare username with no instance" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: "Gitea", value: "hans"})

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).value, &(&1 =~ "name@git.example.com"))
    end

    test "rejects a repository URL: it names no profile" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Forgejo",
          value: "https://git.example.com/hans/project"
        })

      refute changeset.valid?
      assert changeset.errors[:value]
    end

    # The stored value is what the stats client turns into an outbound request,
    # so the shape itself rules out the addresses that would point it inward.
    # (A hostname that merely RESOLVES to one still looks fine here — that is
    # Vutuv.Ssrf's job at fetch time.)
    test "rejects an instance that is not a public dotted hostname" do
      for value <-
            ~w(hans@localhost hans@127.0.0.1 hans@10.0.0.5 hans@[::1] hans@git.example.com:3000) do
        changeset =
          SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
            provider: "Gitea",
            value: value
          })

        refute changeset.valid?, "expected #{value} to be refused"
      end
    end

    test "split_self_hosted/1 answers the pair, or :error for anything else" do
      assert SocialMediaAccount.split_self_hosted("hans@git.example.com") ==
               {:ok, "hans", "git.example.com"}

      assert SocialMediaAccount.split_self_hosted("hans") == :error
      assert SocialMediaAccount.split_self_hosted(nil) == :error
    end

    test "self_hosted_provider?/1 is the chokepoint every caller asks" do
      assert SocialMediaAccount.self_hosted_provider?("Gitea")
      assert SocialMediaAccount.self_hosted_provider?("Forgejo")
      refute SocialMediaAccount.self_hosted_provider?("Codeberg")
      refute SocialMediaAccount.self_hosted_provider?(nil)
    end
  end

  describe "url/1" do
    test "builds the profile URL for GitLab" do
      account = %SocialMediaAccount{provider: "GitLab", value: "wintermeyer"}
      assert SocialMediaAccount.url(account) == "https://gitlab.com/wintermeyer"
    end

    test "builds the profile URL for Codeberg" do
      account = %SocialMediaAccount{provider: "Codeberg", value: "wintermeyer"}
      assert SocialMediaAccount.url(account) == "https://codeberg.org/wintermeyer"
    end

    # One table (@instance_paths) holds the path each instance serves a profile
    # at, so this is the assertion that the table is right for every entry.
    test "builds the profile URL of every provider that carries its own instance" do
      for {provider, value, expected} <- [
            {"Mastodon", "Gargron@mastodon.social", "https://mastodon.social/@Gargron"},
            {"Pixelfed", "dansup@pixelfed.social", "https://pixelfed.social/dansup"},
            {"Gitea", "hans@git.example.com", "https://git.example.com/hans"},
            {"Forgejo", "hans@git.example.com", "https://git.example.com/hans"}
          ] do
        account = %SocialMediaAccount{provider: provider, value: value}
        assert SocialMediaAccount.url(account) == expected
      end
    end

    test "builds the profile URL for Bluesky" do
      account = %SocialMediaAccount{provider: "Bluesky", value: "gargron.bsky.social"}
      assert SocialMediaAccount.url(account) == "https://bsky.app/profile/gargron.bsky.social"
    end

    test "a value that lost its instance yields no link, never a broken one" do
      for provider <- ~w(Mastodon Pixelfed Gitea Forgejo) do
        account = %SocialMediaAccount{provider: provider, value: "hans"}
        assert SocialMediaAccount.url(account) == "", "expected #{provider} to yield no URL"
      end
    end
  end

  # The leading "@" used to live in three hand-copied provider lists (here, the
  # profile card and the CV); display/1 is the one that owns it now.
  describe "display/1" do
    test "leads the federated and Twitter/Instagram handles with an @, others bare" do
      assert SocialMediaAccount.display(%SocialMediaAccount{
               provider: "Pixelfed",
               value: "dansup@pixelfed.social"
             }) == "@dansup@pixelfed.social"

      assert SocialMediaAccount.display(%SocialMediaAccount{
               provider: "Mastodon",
               value: "Gargron@mastodon.social"
             }) == "@Gargron@mastodon.social"

      assert SocialMediaAccount.display(%SocialMediaAccount{
               provider: "GitHub",
               value: "wintermeyer"
             }) == "wintermeyer"
    end
  end

  describe "social_media_link/1" do
    test "builds a link for a supported provider" do
      account = %SocialMediaAccount{provider: "Facebook", value: "vutuv"}
      assert {:safe, _} = SocialMediaAccount.social_media_link(account)
    end

    test "links the handle to the address the provider's own value carries" do
      for {provider, value, href} <- [
            {"Mastodon", "Gargron@mastodon.social", "https://mastodon.social/@Gargron"},
            {"Pixelfed", "dansup@pixelfed.social", "https://pixelfed.social/dansup"},
            {"Bluesky", "gargron.bsky.social", "https://bsky.app/profile/gargron.bsky.social"}
          ] do
        account = %SocialMediaAccount{provider: provider, value: value}
        assert safe_to_string(SocialMediaAccount.social_media_link(account)) =~ ~s(href="#{href}")
      end
    end

    # An empty href is a link back to the page the reader is already on, so a
    # value with no address shows the bare handle instead — the way Snapchat's
    # does, since that provider has no URL scheme at all.
    test "a handle with no address is shown bare, never as an empty link" do
      for provider <- ~w(Mastodon Pixelfed Gitea Forgejo) do
        account = %SocialMediaAccount{provider: provider, value: "orphan"}

        assert SocialMediaAccount.social_media_link(account) in ["orphan", "@orphan"],
               "expected #{provider} to render the bare handle"
      end
    end

    test "returns an empty string for Google+" do
      account = %SocialMediaAccount{provider: "Google+", value: "vutuv"}
      assert SocialMediaAccount.social_media_link(account) == ""
    end
  end

  describe "verification state" do
    test "changeset/2 never casts it — a member cannot set their own mark" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Bluesky",
          value: "alice.bsky.social",
          verified_at: ~N[2026-07-29 10:00:00],
          verification_method: "bluesky_bio"
        })

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :verified_at)
      refute Map.has_key?(changeset.changes, :verification_method)
    end

    test "verification_changeset/2 is the way in" do
      changeset =
        SocialMediaAccount.verification_changeset(%SocialMediaAccount{}, %{
          verification_method: "bluesky_bio",
          verified_at: ~N[2026-07-29 10:00:00],
          last_checked_at: ~N[2026-07-29 10:00:00],
          grace_deadline_at: nil
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :verification_method) == "bluesky_bio"
      assert Ecto.Changeset.get_change(changeset, :verified_at) == ~N[2026-07-29 10:00:00]
    end

    test "a changed handle drops the mark: it proves a different account" do
      verified = %SocialMediaAccount{
        provider: "Bluesky",
        value: "alice.bsky.social",
        verification_method: "bluesky_bio",
        verified_at: ~N[2026-07-29 10:00:00],
        last_checked_at: ~N[2026-07-29 10:00:00],
        grace_deadline_at: ~N[2026-08-05 10:00:00]
      }

      changeset =
        SocialMediaAccount.changeset(verified, %{provider: "Bluesky", value: "bob.bsky.social"})

      assert Ecto.Changeset.get_field(changeset, :verified_at) == nil
      assert Ecto.Changeset.get_field(changeset, :verification_method) == nil
      assert Ecto.Changeset.get_field(changeset, :last_checked_at) == nil
      assert Ecto.Changeset.get_field(changeset, :grace_deadline_at) == nil
    end

    test "re-saving the same handle keeps the mark" do
      verified = %SocialMediaAccount{
        provider: "Bluesky",
        value: "alice.bsky.social",
        verification_method: "bluesky_bio",
        verified_at: ~N[2026-07-29 10:00:00]
      }

      changeset =
        SocialMediaAccount.changeset(verified, %{provider: "Bluesky", value: "alice.bsky.social"})

      assert Ecto.Changeset.get_field(changeset, :verified_at) == ~N[2026-07-29 10:00:00]
      assert Ecto.Changeset.get_field(changeset, :verification_method) == "bluesky_bio"
    end
  end
end
