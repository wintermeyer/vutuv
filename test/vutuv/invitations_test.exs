defmodule Vutuv.InvitationsTest do
  use Vutuv.DataCase, async: false

  import Swoosh.TestAssertions

  alias Vutuv.Invitations
  alias Vutuv.Invitations.Invitation
  alias Vutuv.Invitations.PrefillToken
  alias Vutuv.Repo
  alias Vutuv.Social

  # Pull the invitation token out of the `i=` parameter of the link in an email.
  defp invite_token(body) do
    [_, token] = Regex.run(~r/[?&]i=([A-Za-z0-9_-]+)/, body)
    token
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "first_name" => "Jane",
        "last_name" => "Doe",
        "email" => "jane@example.com",
        "locale" => "en",
        "auto_follow" => false
      },
      overrides
    )
  end

  describe "deliver_invitation/2 — a first invitation" do
    setup do
      %{inviter: insert(:user)}
    end

    test "records the invitation and mails it", %{inviter: inviter} do
      assert {:ok, :sent, _} = Invitations.deliver_invitation(inviter, valid_attrs())

      assert [invitation] = Repo.all(Invitation)
      assert invitation.user_id == inviter.id
      assert invitation.locale == "en"
      assert invitation.auto_follow == false
      assert is_nil(invitation.visited_at)

      assert_email_sent(fn email ->
        assert {_name, "jane@example.com"} = hd(email.to)
        assert email.subject =~ "invited you to vutuv"
      end)
    end

    test "returns an email preview the sender can be shown", %{inviter: inviter} do
      assert {:ok, :sent, preview} = Invitations.deliver_invitation(inviter, valid_attrs())

      assert preview.to_name == "Jane Doe"
      assert preview.to_email == "jane@example.com"
      assert preview.subject =~ "invited you to vutuv"
      assert preview.html_body =~ "<html"
    end

    test "stores only a hash of the normalized address, never the plaintext", %{inviter: inviter} do
      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{"email" => "  Jane@Example.com "})
               )

      assert [invitation] = Repo.all(Invitation)
      assert invitation.email_hash == Invitations.hash_email("jane@example.com")
      refute invitation.email_hash =~ "jane"
    end

    test "carries the personalized message into the email body only when present", %{
      inviter: inviter
    } do
      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{"message" => "Great to have you!"})
               )

      assert_email_sent(fn email ->
        assert email.html_body =~ "Great to have you!"
        assert email.text_body =~ "Great to have you!"
      end)
    end

    test "renders the message as Markdown in the HTML email — a link becomes clickable", %{
      inviter: inviter
    } do
      url = "https://vutuv.de/oliverandrich/posts/019f480d-db7f-77a1-8841-fc517455f42f"

      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{"message" => "Jump into **this**: #{url}"})
               )

      assert_email_sent(fn email ->
        # The HTML body turns the bare URL into a real anchor and renders the
        # Markdown emphasis.
        assert email.html_body =~ ~s(href="#{url}")
        assert email.html_body =~ "<strong>this</strong>"
        # The plain-text alternative keeps the raw Markdown source (readable as-is).
        assert email.text_body =~ url
      end)
    end

    test "greets a known gender with a personal salutation", %{inviter: inviter} do
      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{"locale" => "de", "gender" => "female"})
               )

      assert_email_sent(fn email -> assert email.text_body =~ "Frau Doe" end)

      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{
                   "email" => "herr@example.com",
                   "locale" => "de",
                   "gender" => "male"
                 })
               )

      assert_email_sent(fn email -> assert email.text_body =~ "Herr Doe" end)
    end

    test "prints the inviter's profile URL as the visible link, not the name", %{inviter: inviter} do
      assert {:ok, :sent, _} = Invitations.deliver_invitation(inviter, valid_attrs())
      url = "http://localhost:4000/#{inviter.username}"

      assert_email_sent(fn email ->
        # The URL itself is the anchor text (so the reader learns the
        # vutuv.de/<username> structure), and it links to the profile.
        assert email.html_body =~ ~s(href="#{url}")
        assert email.html_body =~ "#{url}</a>"
        assert email.text_body =~ url
      end)
    end

    test "mentions that a vutuv account is free (not just profile creation)", %{inviter: inviter} do
      assert {:ok, :sent, _} = Invitations.deliver_invitation(inviter, valid_attrs())
      assert_email_sent(fn email -> assert email.text_body =~ "vutuv accounts are free" end)

      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{"email" => "gratis@example.com", "locale" => "de"})
               )

      assert_email_sent(fn email -> assert email.text_body =~ "vutuv-Accounts sind gratis" end)
    end

    test "reassures the recipient about data retention and the one-invite limit", %{
      inviter: inviter
    } do
      assert {:ok, :sent, _} = Invitations.deliver_invitation(inviter, valid_attrs())

      assert_email_sent(fn email ->
        assert email.text_body =~ "only one invitation"
        assert email.text_body =~ "do not store your personal data unasked"
      end)

      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{"email" => "de@example.com", "locale" => "de"})
               )

      assert_email_sent(fn email ->
        assert email.text_body =~ "eine einzige Einladung"
        assert email.text_body =~ "nicht ungefragt"
      end)
    end

    test "the message intro does not repeat the inviter's name", %{inviter: inviter} do
      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{"locale" => "de", "message" => "Schön, dich hier zu sehen!"})
               )

      inviter_name = VutuvWeb.UserHelpers.full_name(inviter)

      assert_email_sent(fn email ->
        refute email.text_body =~ "#{inviter_name} hat Ihnen"
        assert email.text_body =~ "Dazu eine persönliche Nachricht:"
      end)
    end

    test "the invite link carries the prefill data as a compact token", %{inviter: inviter} do
      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{"tag_list" => "Elixir, Cooking"})
               )

      assert_email_sent(fn email ->
        # The point of the compression (issue #913): the link no longer spells
        # the fields out, so it is shorter and keeps the invitee's name and
        # address out of the URL in the clear.
        refute email.text_body =~ "first_name=Jane"
        refute email.text_body =~ "jane%40example.com"

        prefill = email.text_body |> invite_token() |> PrefillToken.decode()

        assert prefill["first_name"] == "Jane"
        assert prefill["last_name"] == "Doe"
        assert prefill["email"] == "jane@example.com"
        # The form field is `tag_list`; it rides the link (and the sign-up page
        # reads it back) as `tags`.
        assert prefill["tags"] == "Elixir, Cooking"
      end)
    end
  end

  describe "deliver_invitation/2 — the once-per-address rule" do
    setup do
      %{inviter: insert(:user)}
    end

    test "a repeat address is a silent no-op with the same outcome shape", %{inviter: inviter} do
      assert {:ok, :sent, _} = Invitations.deliver_invitation(inviter, valid_attrs())
      assert_email_sent()

      # A second attempt for the same address — even by a different member —
      # neither inserts nor mails, and reveals nothing about the first.
      other = insert(:user)
      assert {:ok, :already_invited, _} = Invitations.deliver_invitation(other, valid_attrs())

      refute_email_sent()
      assert Repo.aggregate(Invitation, :count) == 1
    end

    test "the same inviter gets an identical preview on a repeat, so no leak", %{inviter: inviter} do
      assert {:ok, :sent, first} = Invitations.deliver_invitation(inviter, valid_attrs())

      assert {:ok, :already_invited, second} =
               Invitations.deliver_invitation(inviter, valid_attrs())

      # Byte-identical preview whether we sent or silently skipped, so the
      # sender cannot tell a first invite from a repeat.
      assert first == second
    end

    test "the same inviter can invite different addresses", %{inviter: inviter} do
      assert {:ok, :sent, _} = Invitations.deliver_invitation(inviter, valid_attrs())

      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(
                 inviter,
                 valid_attrs(%{"email" => "someone@else.com"})
               )

      assert Repo.aggregate(Invitation, :count) == 2
    end
  end

  describe "deliver_invitation/2 — validation" do
    setup do
      %{inviter: insert(:user)}
    end

    test "requires a first or last name", %{inviter: inviter} do
      attrs = valid_attrs(%{"first_name" => "", "last_name" => ""})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Invitations.deliver_invitation(inviter, attrs)

      assert changeset.action == :insert
      assert %{first_name: [_]} = errors_on(changeset)
      refute_email_sent()
    end

    test "requires a well-formed email", %{inviter: inviter} do
      assert {:error, %Ecto.Changeset{}} =
               Invitations.deliver_invitation(inviter, valid_attrs(%{"email" => "not-an-email"}))

      refute_email_sent()
    end

    test "rejects an unsupported language", %{inviter: inviter} do
      assert {:error, %Ecto.Changeset{}} =
               Invitations.deliver_invitation(inviter, valid_attrs(%{"locale" => "fr"}))
    end
  end

  describe "deliver_invitation/2 — the per-inviter daily cap" do
    test "refuses once the inviter hits today's cap, without leaking the address" do
      inviter = insert(:user)

      # Fill the day's quota directly (cheaper than sending `daily_cap` emails).
      for n <- 1..Invitations.daily_cap() do
        Repo.insert!(%Invitation{
          user_id: inviter.id,
          email_hash: Invitations.hash_email("filler#{n}@example.com"),
          locale: "en"
        })
      end

      assert {:error, :rate_limited} = Invitations.deliver_invitation(inviter, valid_attrs())
      refute_email_sent()
      # No new row for the refused address.
      assert Repo.aggregate(Invitation, :count) == Invitations.daily_cap()
    end

    test "the cap is per inviter, not global" do
      capped = insert(:user)

      for n <- 1..Invitations.daily_cap() do
        Repo.insert!(%Invitation{
          user_id: capped.id,
          email_hash: Invitations.hash_email("filler#{n}@example.com"),
          locale: "en"
        })
      end

      fresh = insert(:user)
      assert {:ok, :sent, _} = Invitations.deliver_invitation(fresh, valid_attrs())
    end
  end

  describe "record_visit/1" do
    test "stamps visited_at the first time, and never again" do
      inviter = insert(:user)
      assert {:ok, :sent, _} = Invitations.deliver_invitation(inviter, valid_attrs())

      Invitations.record_visit("jane@example.com")
      first = Repo.one(Invitation)
      assert first.visited_at

      # Back-date the stamp, then visit again: the second visit must not move it.
      earlier = ~N[2020-01-01 00:00:00]
      Repo.update_all(Invitation, set: [visited_at: earlier])
      Invitations.record_visit("jane@example.com")

      assert Repo.one(Invitation).visited_at == earlier
    end

    test "is a no-op for a blank or unknown address" do
      assert Invitations.record_visit(nil) == :ok
      assert Invitations.record_visit("   ") == :ok
      assert Invitations.record_visit("stranger@example.com") == :ok
    end
  end

  describe "apply_auto_follow/2" do
    test "the inviter follows the new member when the flag was set" do
      inviter = insert(:user)

      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(inviter, valid_attrs(%{"auto_follow" => true}))

      newcomer = insert(:user)
      assert Invitations.apply_auto_follow("jane@example.com", newcomer) == :ok

      assert is_binary(Social.follow_id(inviter.id, newcomer.id))
    end

    test "does nothing when the flag was not set" do
      inviter = insert(:user)

      assert {:ok, :sent, _} =
               Invitations.deliver_invitation(inviter, valid_attrs(%{"auto_follow" => false}))

      newcomer = insert(:user)
      Invitations.apply_auto_follow("jane@example.com", newcomer)

      assert is_nil(Social.follow_id(inviter.id, newcomer.id))
    end

    test "does nothing for an address that was never invited" do
      newcomer = insert(:user)
      assert Invitations.apply_auto_follow("stranger@example.com", newcomer) == :ok
    end
  end

  describe "hash_email/1 and normalize_email/1" do
    test "normalization makes trimming and case irrelevant" do
      assert Invitations.normalize_email("  Foo@Bar.COM ") == "foo@bar.com"
      assert Invitations.hash_email("  Foo@Bar.COM ") == Invitations.hash_email("foo@bar.com")
    end

    test "is a keyed HMAC, not the brute-forceable bare SHA-256 (issue #942)" do
      normalized = "jane@example.com"
      bare_sha256 = :sha256 |> :crypto.hash(normalized) |> Base.encode16(case: :lower)

      # An attacker who reads the invitations table must NOT be able to confirm a
      # guessed address by computing its plain SHA-256 — the hash is keyed by a
      # server secret held outside the database.
      refute Invitations.hash_email(normalized) == bare_sha256

      # Still deterministic (so the unique-index dedup keeps working) and still
      # shaped like a SHA-256 digest (64 lowercase hex chars).
      assert Invitations.hash_email(normalized) == Invitations.hash_email(" Jane@Example.com ")
      assert Invitations.hash_email(normalized) =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  describe "reseed_dedup/2 (issue #942 post-cutover restore)" do
    setup do
      %{inviter: insert(:user)}
    end

    test "inserts one dedup row per normalized address, trimming and downcasing",
         %{inviter: inviter} do
      emails = [
        "  Jane@Example.com ",
        "bob@example.com",
        "jane@example.com",
        "  ",
        "bob@EXAMPLE.com"
      ]

      summary = Invitations.reseed_dedup(emails, inviter)

      # Five entries collapse to two distinct normalized addresses.
      assert summary.inserted == 2
      assert summary.total == 2

      assert Repo.get_by(Invitation, email_hash: Invitations.hash_email("jane@example.com"))
      assert Repo.get_by(Invitation, email_hash: Invitations.hash_email("bob@example.com"))
    end

    test "is idempotent — re-running inserts nothing", %{inviter: inviter} do
      emails = ["jane@example.com", "bob@example.com"]
      assert Invitations.reseed_dedup(emails, inviter).inserted == 2
      assert Invitations.reseed_dedup(emails, inviter).inserted == 0
    end

    test "a reseeded address is then treated as already invited (no second email)",
         %{inviter: inviter} do
      Invitations.reseed_dedup(["jane@example.com"], inviter)

      assert {:ok, :already_invited, _preview} =
               Invitations.deliver_invitation(inviter, valid_attrs())

      assert_no_email_sent()
    end
  end
end
