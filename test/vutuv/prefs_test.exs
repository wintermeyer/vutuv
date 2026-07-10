defmodule Vutuv.PrefsTest do
  # async: false — several tests inject installation defaults into the
  # persistent_term cache (Vutuv.Prefs.Cache.store/1), which is node-global
  # state that async tests reading prefs (every post render) would observe.
  use Vutuv.DataCase, async: false

  alias Vutuv.Accounts.User
  alias Vutuv.Prefs
  alias Vutuv.Prefs.Cache
  alias Vutuv.Prefs.Default
  alias Vutuv.Prefs.Pref

  # Install `overrides` as the cached installation defaults for one test.
  defp with_installation_defaults(overrides) do
    Cache.store(Map.merge(Prefs.shipped_defaults(), overrides))
    on_exit(fn -> Cache.clear() end)
  end

  describe "registry/0" do
    test "every pref maps onto a nullable User schema field with no struct default" do
      user = %User{}

      for %Pref{} = pref <- Prefs.registry() do
        assert pref.key in User.__schema__(:fields),
               "#{pref.key} is not a users column"

        # The shipped default lives ONLY in the registry: a fresh struct (and a
        # fresh row) holds nil = "inherit the installation default".
        assert Map.fetch!(user, pref.key) == nil,
               "#{pref.key} still carries an Ecto schema default; move it to the registry"
      end
    end

    test "definitions are internally consistent" do
      for %Pref{} = pref <- Prefs.registry() do
        case pref.type do
          :integer ->
            assert pref.min <= pref.default and pref.default <= pref.max

          :boolean ->
            assert is_boolean(pref.default)

          :select ->
            assert pref.default in pref.values
        end

        # Every pref renders in the admin UI, so it needs a label and a group.
        assert is_binary(Prefs.label(pref.key))
        assert is_binary(Prefs.group_label(pref.group))
      end
    end
  end

  describe "parse/2 and dump/2" do
    test "round-trips every pref's shipped default" do
      for pref <- Prefs.registry() do
        assert {:ok, pref.default} == Prefs.parse(pref, Prefs.dump(pref, pref.default))
      end
    end

    test "rejects junk, out-of-range integers and unknown select values" do
      lines = Prefs.pref!(:post_lines_desktop)
      assert :error = Prefs.parse(lines, "abc")
      assert :error = Prefs.parse(lines, "-1")
      assert :error = Prefs.parse(lines, "999")
      assert {:ok, 0} = Prefs.parse(lines, "0")

      hyphenate = Prefs.pref!(:post_hyphenate_mobile)
      assert :error = Prefs.parse(hyphenate, "yes")
      assert {:ok, false} = Prefs.parse(hyphenate, "false")

      map = Prefs.pref!(:default_map_service)
      assert :error = Prefs.parse(map, "bing")
      assert {:ok, "apple"} = Prefs.parse(map, "apple")
    end
  end

  describe "installation defaults" do
    test "fall back to the shipped defaults while the cache holds nothing" do
      assert Prefs.installation_defaults() == Prefs.shipped_defaults()
      assert Prefs.default(:post_lines_desktop) == 6
      assert Prefs.default(:post_hyphenate_mobile) == true
      assert Prefs.default(:default_map_service) == "google"
    end

    test "an admin-set default overrides the shipped one" do
      with_installation_defaults(%{post_lines_desktop: 12, map_google?: false})

      assert Prefs.default(:post_lines_desktop) == 12
      assert Prefs.default(:map_google?) == false
      # Untouched keys keep the shipped value.
      assert Prefs.default(:post_lines_mobile) == 8
    end

    test "put_defaults/1 stores overrides and drops rows equal to the shipped default" do
      assert {:ok, _} =
               Prefs.put_defaults(%{
                 "post_lines_desktop" => "10",
                 "post_lines_mobile" => "8"
               })

      assert Prefs.list_default_rows() == %{post_lines_desktop: "10"}

      # Setting it back to the shipped value removes the override row.
      assert {:ok, _} = Prefs.put_defaults(%{"post_lines_desktop" => "6"})
      assert Prefs.list_default_rows() == %{}
    end

    test "put_defaults/1 rejects invalid values without writing anything" do
      assert {:error, invalid} =
               Prefs.put_defaults(%{
                 "post_lines_desktop" => "999",
                 "post_lines_mobile" => "4"
               })

      assert invalid == [:post_lines_desktop]
      assert Prefs.list_default_rows() == %{}
    end

    test "load_installation_defaults/0 ignores unknown keys and un-parseable values" do
      Repo.insert!(%Default{key: "retired_pref", value: "42"})
      Repo.insert!(%Default{key: "post_lines_desktop", value: "not a number"})
      Repo.insert!(%Default{key: "post_lines_mobile", value: "3"})

      defaults = Prefs.load_installation_defaults()
      assert defaults.post_lines_mobile == 3
      assert defaults.post_lines_desktop == 6
      refute Map.has_key?(defaults, :retired_pref)
    end
  end

  describe "resolution" do
    test "a member's explicit value wins over the installation default" do
      with_installation_defaults(%{post_lines_desktop: 12})
      user = %User{post_lines_desktop: 4}

      assert Prefs.get(user, :post_lines_desktop) == 4
    end

    test "an explicit 0 or false is a choice, not an absence" do
      with_installation_defaults(%{post_lines_desktop: 12, post_hyphenate_mobile: true})
      user = %User{post_lines_desktop: 0, post_hyphenate_mobile: false}

      assert Prefs.get(user, :post_lines_desktop) == 0
      assert Prefs.get(user, :post_hyphenate_mobile) == false
    end

    test "a nil field and a nil viewer inherit the installation default" do
      with_installation_defaults(%{post_lines_desktop: 12})

      assert Prefs.get(%User{}, :post_lines_desktop) == 12
      assert Prefs.get(nil, :post_lines_desktop) == 12
    end

    test "with_effective/1 fills only the inherited fields" do
      with_installation_defaults(%{post_lines_desktop: 12})
      user = Prefs.with_effective(%User{post_lines_mobile: 3})

      assert user.post_lines_desktop == 12
      assert user.post_lines_mobile == 3
    end

    test "customized_in_group?/2 reports whether any field in the group is explicit" do
      refute Prefs.customized_in_group?(%User{}, :post_display)
      assert Prefs.customized_in_group?(%User{post_lines_desktop: 0}, :post_display)
      refute Prefs.customized_in_group?(%User{post_lines_desktop: 0}, :maps)
    end
  end

  describe "per-member admin overrides" do
    test "admin_update_user/2 sets explicit values and clears back to inherit" do
      user = insert(:user)

      assert {:ok, updated} =
               Prefs.admin_update_user(user, %{
                 "post_lines_desktop" => "4",
                 "map_google?" => "false",
                 "default_map_service" => "apple"
               })

      assert updated.post_lines_desktop == 4
      assert updated.map_google? == false
      assert updated.default_map_service == "apple"

      # A blank means "back to the installation default" (nil).
      assert {:ok, cleared} =
               Prefs.admin_update_user(updated, %{
                 "post_lines_desktop" => "",
                 "map_google?" => "",
                 "default_map_service" => ""
               })

      assert cleared.post_lines_desktop == nil
      assert cleared.map_google? == nil
      assert cleared.default_map_service == nil
    end

    test "admin_update_user/2 rejects invalid values without writing" do
      user = insert(:user)

      assert {:error, [:post_lines_desktop]} =
               Prefs.admin_update_user(user, %{"post_lines_desktop" => "999"})

      assert Repo.get!(User, user.id).post_lines_desktop == nil
    end

    test "reset_group/2 nils exactly the group's fields" do
      user = insert(:user)

      {:ok, user} =
        Prefs.admin_update_user(user, %{"post_lines_desktop" => "4", "map_google?" => "false"})

      assert {:ok, reset} = Prefs.reset_group(user, :post_display)
      assert reset.post_lines_desktop == nil
      assert reset.map_google? == false
    end
  end

  describe "User.post_prefs/1 through the installation defaults" do
    test "an untouched member and a logged-out reader follow the admin default" do
      with_installation_defaults(%{post_lines_desktop: 12, post_hyphenate_desktop: true})

      assert User.post_prefs(%User{}).lines_desktop == 12
      assert User.post_prefs(%User{}).hyphenate_desktop == true
      assert User.post_prefs(nil).lines_desktop == 12
    end

    test "explicit member choices still win" do
      with_installation_defaults(%{post_lines_desktop: 12})
      prefs = User.post_prefs(%User{post_lines_desktop: 0, post_hyphenate_mobile: false})

      assert prefs.lines_desktop == 0
      assert prefs.hyphenate_mobile == false
    end
  end

  describe "Vutuv.Maps through the installation defaults" do
    test "an untouched member and a logged-out visitor follow the admin defaults" do
      with_installation_defaults(%{map_google?: false, default_map_service: "apple"})

      assert Vutuv.Maps.enabled_services(%User{}) == [:openstreetmap, :apple]
      assert Vutuv.Maps.enabled_services(nil) == [:openstreetmap, :apple]
      assert Vutuv.Maps.default_service(%User{}) == :apple
    end

    test "explicit member choices still win over the admin defaults" do
      with_installation_defaults(%{map_google?: false, default_map_service: "apple"})
      user = %User{map_google?: true, default_map_service: "google"}

      assert :google in Vutuv.Maps.enabled_services(user)
      assert Vutuv.Maps.default_service(user) == :google
    end
  end
end
